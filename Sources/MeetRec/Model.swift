import AppKit
import AVFoundation
import Foundation

struct Config: Decodable {
    let recordingsDir: String

    static let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/meetrec/config.json")

    static func load() throws -> Config {
        guard let data = try? Data(contentsOf: url) else {
            throw NSError(domain: "MeetRec", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Missing ~/.config/meetrec/config.json"])
        }
        return try JSONDecoder().decode(Config.self, from: data)
    }
}

@MainActor
final class Model: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case recording(since: Date)
        case stopping
        case saved(length: String)
        case processing(stage: String)
        case done
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var title = ""
    @Published var systemLevel: Float = 0
    @Published var micLevel: Float = 0

    /// Folder of the latest recording: the one Process acts on.
    private(set) var directory: URL?
    private var startedAt = Date()
    private let recorder = Recorder()

    init() {
        recorder.onLevels = { [weak self] system, mic in
            Task { @MainActor in
                self?.systemLevel = system
                self?.micLevel = mic
            }
        }
        recorder.onInterrupted = { [weak self] message in
            Task { @MainActor in await self?.finishRecording(note: "Capture ended early: \(message)") }
        }
    }

    var isBusy: Bool {
        switch phase {
        case .starting, .stopping, .processing: return true
        default: return false
        }
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    // MARK: Recording

    func toggleRecording() {
        if isRecording {
            Task { await finishRecording(note: nil) }
        } else if !isBusy {
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        phase = .starting
        directory = nil
        var created: URL?
        do {
            let config = try Config.load()
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            let now = Date()
            let directory = try makeDirectory(root: config.recordingsDir, date: now)
            created = directory
            try await recorder.start(in: directory)
            self.directory = directory
            startedAt = now
            writeMeta(tracks: [:], endedAt: nil, note: nil)
            phase = .recording(since: now)
        } catch {
            // Do not leave an empty folder behind for a recording that never began.
            if let created { try? FileManager.default.removeItem(at: created) }
            let nsError = error as NSError
            // -3801 is ScreenCaptureKit's "user declined": system audio rides on the Screen Recording permission.
            if nsError.domain == SCStreamErrorDomainName || nsError.code == -3801 {
                phase = .failed("Allow Screen & System Audio Recording, then press record again")
                openPrivacySettings()
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func finishRecording(note: String?) async {
        guard isRecording else { return }
        phase = .stopping
        let tracks = await recorder.stop()
        let ended = Date()
        writeMeta(tracks: tracks, endedAt: ended, note: note)
        systemLevel = 0
        micLevel = 0
        let seconds = Int(ended.timeIntervalSince(startedAt))
        let length = String(format: "%d:%02d", seconds / 60, seconds % 60)
        let captured = tracks.values.contains { $0.firstPTS != nil }
        if !captured {
            phase = .failed("Nothing was captured. Check the recording permission.")
            return
        }
        phase = .saved(length: length)
        // Build the listenable mix right away so the audio exists even if Transcribe is never clicked.
        if let directory {
            Task.detached { _ = await Pipeline.run(directory: directory, stage: "mix") { _ in } }
        }
    }

    private func makeDirectory(root: String, date: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        var name = formatter.string(from: date)
        let slug = Self.slug(title)
        if !slug.isEmpty { name += "-" + slug }
        let rootURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
        let directory = rootURL.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeMeta(tracks: [String: TrackInfo], endedAt: Date?, note: String?) {
        guard let directory else { return }
        let iso = ISO8601DateFormatter()
        var meta: [String: Any] = ["title": title, "startedAt": iso.string(from: startedAt)]
        if let endedAt { meta["endedAt"] = iso.string(from: endedAt) }
        if let note { meta["note"] = note }
        var trackMeta: [String: Any] = [:]
        for (name, info) in tracks {
            var entry: [String: Any] = ["file": info.file]
            if let pts = info.firstPTS { entry["firstPTS"] = pts }
            if let failure = info.failure { entry["failure"] = failure }
            trackMeta[name] = entry
        }
        meta["tracks"] = trackMeta
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("meta.json"))
        }
    }

    // MARK: Processing

    /// Mixes the tracks and turns them into text, next to the audio.
    func process() {
        guard directory != nil, !isBusy, !isRecording else { return }
        // The name can be typed after the call: apply it before the text is written.
        applyTitle()
        guard let directory else { return }
        phase = .processing(stage: "Starting")
        Task {
            let status = await Pipeline.run(directory: directory, stage: "transcribe") { [weak self] stage in
                Task { @MainActor in
                    if case .processing = self?.phase { self?.phase = .processing(stage: stage) }
                }
            }
            phase = status == 0 ? .done : .failed("Transcription failed. Right-click for the log.")
        }
    }

    struct Meeting: Identifiable {
        let name: String
        let hasText: Bool
        var id: String { name }
    }

    /// Every recording on disk, newest first.
    func meetings() -> [Meeting] {
        guard let config = try? Config.load() else { return [] }
        let root = URL(fileURLWithPath: (config.recordingsDir as NSString).expandingTildeInPath)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { Meeting(name: $0.lastPathComponent,
                           hasText: FileManager.default.fileExists(atPath: $0.appendingPathComponent("transcript.txt").path)) }
            .sorted { $0.name > $1.name }
    }

    /// Picking an old meeting copies its name; one without text is also loaded so it can be transcribed.
    func pick(_ meeting: Meeting) {
        guard !isBusy, !isRecording, let config = try? Config.load() else { return }
        let root = URL(fileURLWithPath: (config.recordingsDir as NSString).expandingTildeInPath)
        directory = root.appendingPathComponent(meeting.name)
        title = meeting.name.count > 16 ? String(meeting.name.dropFirst(16)).replacingOccurrences(of: "-", with: " ") : ""
        copyName()
        phase = meeting.hasText ? .done : .saved(length: "")
    }

    private func recordingsRoot() -> URL? {
        guard let config = try? Config.load() else { return nil }
        return URL(fileURLWithPath: (config.recordingsDir as NSString).expandingTildeInPath)
    }

    func openRecordingsFolder() {
        guard let root = recordingsRoot() else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    /// Moves a recording to the Trash, so a wrong click can be undone from there.
    func delete(_ meeting: Meeting) {
        guard !isBusy, !isRecording, let root = recordingsRoot() else { return }
        let target = root.appendingPathComponent(meeting.name)
        do {
            try FileManager.default.trashItem(at: target, resultingItemURL: nil)
            if directory?.lastPathComponent == meeting.name {
                directory = nil
                title = ""
                phase = .idle
            }
        } catch {
            phase = .failed("Could not delete: \(error.localizedDescription)")
        }
    }

    /// Asks for a new recordings folder and stores it in the config. Existing recordings stay where they are.
    func changeRecordingsFolder() {
        guard !isBusy, !isRecording else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        panel.message = "Where should new recordings be saved?"
        panel.directoryURL = recordingsRoot()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: Config.url),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            settings = existing
        }
        settings["recordingsDir"] = (chosen.path as NSString).abbreviatingWithTildeInPath
        do {
            try FileManager.default.createDirectory(at: Config.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: Config.url)
            // The loaded meeting belongs to the old folder.
            directory = nil
            title = ""
            phase = .idle
        } catch {
            phase = .failed("Could not save the folder: \(error.localizedDescription)")
        }
    }

    /// Stops and saves a running recording, then closes the app.
    func quit() {
        Task {
            if isRecording { await finishRecording(note: nil) }
            NSApp.terminate(nil)
        }
    }

    /// The meeting's name: its folder name, which is what an agent needs to find it.
    var meetingName: String { directory?.lastPathComponent ?? "" }

    func copyName() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("meeting: \(meetingName)", forType: .string)
    }

    /// Renames the folder when a name was typed after recording started, and stores it in meta.json.
    private func applyTitle() {
        guard let current = directory else { return }
        let slug = Self.slug(title)
        let stamp = String(current.lastPathComponent.prefix(15)) // yyyy-MM-dd-HHmm
        let wanted = slug.isEmpty ? stamp : stamp + "-" + slug
        if wanted != current.lastPathComponent {
            let renamed = current.deletingLastPathComponent().appendingPathComponent(wanted)
            if (try? FileManager.default.moveItem(at: current, to: renamed)) != nil { directory = renamed }
        }
        guard let directory else { return }
        let url = directory.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url),
              var meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        meta["title"] = title
        if let updated = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? updated.write(to: url)
        }
    }

    static func slug(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    // MARK: Shortcuts

    func openTranscript() {
        guard let directory else { return }
        NSWorkspace.shared.open(directory.appendingPathComponent("transcript.txt"))
    }

    func openLog() {
        guard let directory else { return }
        NSWorkspace.shared.open(directory.appendingPathComponent("process.log"))
    }

    func revealRecordings() {
        if let directory {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } else if let config = try? Config.load() {
            NSWorkspace.shared.open(URL(fileURLWithPath: (config.recordingsDir as NSString).expandingTildeInPath))
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

private let SCStreamErrorDomainName = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"

/// Runs the bundled processing script and reports its stages.
enum Pipeline {
    static func run(directory: URL, stage: String, onStage: @escaping (String) -> Void) async -> Int32 {
        guard let script = Bundle.main.url(forResource: "process", withExtension: "sh") else { return 127 }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [script.path, directory.path, stage]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let lines = LineBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                for line in lines.feed(handle.availableData) where line.hasPrefix("STAGE: ") {
                    onStage(String(line.dropFirst(7)))
                }
            }
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: 126)
            }
        }
    }
}

/// Splits a byte stream into lines. Only ever touched from the pipe's own reading queue.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    func feed(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
}
