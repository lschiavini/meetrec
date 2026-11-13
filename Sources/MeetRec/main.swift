import AppKit
import SwiftUI

/// Borderless panels refuse keyboard focus by default; the title field needs it.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct LevelDot: View {
    let level: Float
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(level > 0.01 ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
                .scaleEffect(1 + CGFloat(min(level, 1)) * 0.8)
                .animation(.linear(duration: 0.1), value: level)
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
        }
        .help(label == "pc" ? "Sound coming out of the computer" : "Your microphone")
    }
}

struct PanelView: View {
    @ObservedObject var model: Model

    var body: some View {
        HStack(spacing: 10) {
            Button(action: model.toggleRecording) {
                Image(systemName: model.isRecording ? "stop.fill" : "record.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(model.isBusy ? Color.secondary : Color.red)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .help(model.isRecording ? "Stop and save" : "Record computer audio and microphone")

            status

            Spacer(minLength: 0)

            if model.isRecording {
                LevelDot(level: model.systemLevel, label: "pc")
                LevelDot(level: model.micLevel, label: "mic")
            }
            if case .saved = model.phase {
                Button("Transcribe", action: model.process).controlSize(.small)
            }
            if case .failed = model.phase, model.directory != nil {
                Button("Retry", action: model.process).controlSize(.small)
            }
            if case .done = model.phase {
                Button("Copy name", action: model.copyName).controlSize(.small)
                    .help("Copies \"meeting: \(model.meetingName)\" to paste to an agent")
            }
            if !model.isRecording && !model.isBusy {
                Menu {
                    let meetings = model.meetings()
                    if meetings.isEmpty { Text("No meetings yet") }
                    ForEach(meetings) { meeting in
                        Button(meeting.hasText ? meeting.name : "\(meeting.name)  (no text yet)") { model.pick(meeting) }
                    }
                    Divider()
                    Menu("Delete a recording") {
                        ForEach(meetings) { meeting in
                            Button(meeting.name, role: .destructive) { model.delete(meeting) }
                        }
                    }
                    .disabled(meetings.isEmpty)
                    Button("Open recordings folder", action: model.openRecordingsFolder)
                    Button("Change recordings folder…", action: model.changeRecordingsFolder)
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Earlier meetings: pick one to copy its name. Also delete, open folder, change folder.")
            }
            Button(action: model.quit) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .help(model.isRecording ? "Stop, save and close" : "Close MeetRec")
        }
        .padding(.horizontal, 12)
        .frame(width: 380, height: 46)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
        .contextMenu {
            Button("Show recording in Finder", action: model.revealRecordings)
            Button("Open recordings folder", action: model.openRecordingsFolder)
            Button("Change recordings folder…", action: model.changeRecordingsFolder)
            Button("Open transcript", action: model.openTranscript).disabled(model.phase != .done)
            Button("Open log", action: model.openLog).disabled(model.directory == nil)
            Divider()
            Button("Quit MeetRec", action: model.quit)
        }
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .idle:
            titleField
        case .starting:
            Text("Starting…").foregroundStyle(.secondary)
        case .recording(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60)).monospacedDigit()
            }
            titleField
        case .stopping:
            Text("Saving…").foregroundStyle(.secondary)
        case .saved(let length):
            Text(length.isEmpty ? "Not transcribed" : "Saved \(length)").monospacedDigit()
            titleField
        case .processing(let stage):
            ProgressView().controlSize(.small)
            Text(stage).lineLimit(1).foregroundStyle(.secondary)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Text ready").help(model.meetingName)
        case .failed(let message):
            Text(message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2).help(message)
        }
    }

    private var titleField: some View {
        TextField("Meeting name (optional)", text: $model.title)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .frame(maxWidth: 150)
    }
}

@MainActor
func makePanel(model: Model) -> FloatingPanel {
    let host = NSHostingView(rootView: PanelView(model: model))
    let panel = FloatingPanel(
        contentRect: NSRect(origin: .zero, size: host.fittingSize),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)
    panel.contentView = host
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .statusBar
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    return panel
}

/// Shows the panel in each state with made-up data and saves a PNG of each, for the README.
@MainActor
func saveScreenshots(to directory: String) async {
    let shots: [(name: String, phase: Model.Phase, title: String)] = [
        ("idle", .idle, ""),
        ("recording", .recording(since: Date().addingTimeInterval(-754)), "Design review"),
        ("transcribing", .processing(stage: "Transcribing…"), ""),
        ("done", .done, ""),
    ]
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for shot in shots {
        let model = Model()
        model.phase = shot.phase
        model.title = shot.title
        model.systemLevel = 0.6
        model.micLevel = 0.3
        let panel = makePanel(model: model)
        panel.setFrameOrigin(NSPoint(x: 200, y: 400))
        panel.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 800_000_000)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(panel.windowNumber), "\(directory)/\(shot.name).png"]
        try? capture.run()
        capture.waitUntilExit()
        panel.orderOut(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel!
    private let model = Model()

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = makePanel(model: model)
        let size = panel.frame.size
        // Keeps the panel out of screenshots, recordings and screen shares.
        panel.sharingType = .none

        let autosave = "MeetRecPanel"
        if UserDefaults.standard.string(forKey: "NSWindow Frame \(autosave)") == nil, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20))
        }
        panel.setFrameAutosaveName(autosave)
        panel.orderFrontRegardless()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting mid-recording would leave the files unclosed.
        model.isRecording ? .terminateCancel : .terminateNow
    }
}

// `MeetRec --selftest DIR [SECONDS]` records for a few seconds without the panel and prints what was captured.
if let flag = CommandLine.arguments.firstIndex(of: "--selftest"), CommandLine.arguments.count > flag + 1 {
    let directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    let seconds = CommandLine.arguments.count > flag + 2 ? Double(CommandLine.arguments[flag + 2]) ?? 4 : 4
    let recorder = Recorder()
    Task {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await recorder.start(in: directory)
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let tracks = await recorder.stop()
            for (name, info) in tracks.sorted(by: { $0.key < $1.key }) {
                print(name, info.file, "firstPTS:", info.firstPTS.map { String($0) } ?? "none", "failure:", info.failure ?? "none")
            }
            exit(tracks.values.contains { $0.firstPTS != nil } ? 0 : 1)
        } catch {
            print("selftest failed:", error)
            exit(1)
        }
    }
    dispatchMain()
}

// `MeetRec --screenshots DIR` saves a PNG of the panel in each state, for the README.
if let flag = CommandLine.arguments.firstIndex(of: "--screenshots"), CommandLine.arguments.count > flag + 1 {
    let directory = CommandLine.arguments[flag + 1]
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            await saveScreenshots(to: directory)
            exit(0)
        }
        NSApplication.shared.run()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
