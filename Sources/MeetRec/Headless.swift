import AVFoundation
import Foundation

/// `MeetRec --record --status FILE [--name TITLE] [--dir ROOT]` records with no panel until it gets
/// SIGTERM or SIGINT, then closes the files and exits. The `meetrec` CLI launches it through
/// `open`, so the capture runs as MeetRec.app and uses the app's recording permissions.
///
/// The status file holds one tab-separated line the CLI polls:
///   recording <dir> <pid>    capture is running
///   saved     <dir>          files closed, meta.json written
///   failed    <message>      nothing was recorded
enum Headless {
    static func record(arguments: [String]) -> Never {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
            return arguments[index + 1]
        }
        let title = value("--name") ?? ""
        let statusURL = value("--status").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

        func report(_ fields: String...) {
            let line = fields.joined(separator: "\t") + "\n"
            if let statusURL {
                try? line.write(to: statusURL, atomically: true, encoding: .utf8)
            } else {
                FileHandle.standardError.write(line.data(using: .utf8)!)
            }
        }

        let recorder = Recorder()
        let lock = NSLock()
        var directory: URL?
        var startedAt = Date()
        var stopping = false

        func finish(note: String?) {
            lock.lock()
            if stopping { lock.unlock(); return }
            stopping = true
            lock.unlock()
            Task {
                let tracks = await recorder.stop()
                guard let directory else { report("failed", "stopped before the capture began"); exit(1) }
                RecordingFolder.writeMeta(in: directory, title: title, startedAt: startedAt,
                                          tracks: tracks, endedAt: Date(), note: note)
                if tracks.values.contains(where: { $0.firstPTS != nil }) {
                    report("saved", directory.path)
                    exit(0)
                }
                try? FileManager.default.removeItem(at: directory)
                report("failed", "Nothing was captured. Check the recording permission.")
                exit(1)
            }
        }

        // Signals arrive on a dispatch source instead of interrupting the process.
        var sources: [DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { finish(note: nil) }
            source.resume()
            sources.append(source)
        }
        recorder.onInterrupted = { message in finish(note: "Capture ended early: \(message)") }

        Task {
            var created: URL?
            do {
                let root: String
                if let override = value("--dir") { root = override } else { root = try Config.load().recordingsDir }
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                let now = Date()
                let folder = try RecordingFolder.create(root: root, title: title, date: now)
                created = folder
                try await recorder.start(in: folder)
                directory = folder
                startedAt = now
                RecordingFolder.writeMeta(in: folder, title: title, startedAt: now, tracks: [:], endedAt: nil, note: nil)
                report("recording", folder.path, String(getpid()))
            } catch {
                if let created { try? FileManager.default.removeItem(at: created) }
                let nsError = error as NSError
                if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" || nsError.code == -3801 {
                    report("failed", "Allow Screen & System Audio Recording for MeetRec in System Settings > Privacy & Security")
                } else {
                    report("failed", error.localizedDescription)
                }
                exit(1)
            }
        }
        _ = sources
        dispatchMain()
    }
}
