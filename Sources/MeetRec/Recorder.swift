import AVFoundation
import ScreenCaptureKit

/// Writes one audio track to disk. The writer is created from the first buffer,
/// so the file always matches whatever format the device actually delivers.
final class TrackWriter {
    let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private(set) var firstPTS: Double?
    private(set) var failure: String?

    init(url: URL) { self.url = url }

    func append(_ buffer: CMSampleBuffer) {
        guard failure == nil, CMSampleBufferDataIsReady(buffer), CMSampleBufferGetNumSamples(buffer) > 0 else { return }
        if writer == nil { open(with: buffer) }
        guard let input, failure == nil, input.isReadyForMoreMediaData else { return }
        if !input.append(buffer) {
            failure = writer?.error?.localizedDescription ?? "append failed"
        }
    }

    private func open(with buffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return }
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            // Fragments keep the file readable if the app dies mid-meeting.
            writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
            let channels = max(1, min(2, Int(asbd.mChannelsPerFrame)))
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: asbd.mSampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 2 ? 128_000 : 64_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { failure = "cannot add audio input"; return }
            writer.add(input)
            guard writer.startWriting() else {
                failure = writer.error?.localizedDescription ?? "cannot start writing"
                return
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            writer.startSession(atSourceTime: pts)
            firstPTS = pts.seconds
            self.writer = writer
            self.input = input
        } catch {
            failure = error.localizedDescription
        }
    }

    func finish() async {
        guard let writer, writer.status == .writing else { return }
        input?.markAsFinished()
        await writer.finishWriting()
    }
}

struct TrackInfo {
    let file: String
    let firstPTS: Double?
    let failure: String?
}

/// Captures system audio and the microphone as two separate tracks.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "meetrec.audio")
    private var system: TrackWriter?
    private var mic: TrackWriter?
    private var lastLevelPush = Date.distantPast
    private var peakSystem: Float = 0
    private var peakMic: Float = 0
    /// Host-clock time when the capture was requested. Buffers stamped earlier are leftovers and get dropped.
    private var startTime = CMTime.zero

    /// Called on the main queue, about ten times a second.
    var onLevels: ((Float, Float) -> Void)?
    /// Called on the main queue if the system ends the capture on its own.
    var onInterrupted: ((String) -> Void)?

    func start(in directory: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "MeetRec", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Video is required by the API but unused: keep it as small and slow as allowed.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        queue.sync {
            startTime = CMClockGetTime(CMClockGetHostTimeClock())
            system = TrackWriter(url: directory.appendingPathComponent("system.mov"))
            mic = TrackWriter(url: directory.appendingPathComponent("mic.mov"))
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Stops the capture and closes both files.
    func stop() async -> [String: TrackInfo] {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        return await closeFiles()
    }

    private func closeFiles() async -> [String: TrackInfo] {
        let (system, mic) = queue.sync { () -> (TrackWriter?, TrackWriter?) in
            let pair = (self.system, self.mic)
            self.system = nil
            self.mic = nil
            return pair
        }
        await system?.finish()
        await mic?.finish()
        var tracks: [String: TrackInfo] = [:]
        if let system { tracks["system"] = TrackInfo(file: "system.mov", firstPTS: system.firstPTS, failure: system.failure) }
        if let mic { tracks["mic"] = TrackInfo(file: "mic.mov", firstPTS: mic.firstPTS, failure: mic.failure) }
        return tracks
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // The first system-audio buffer can carry a timestamp from long before the capture began,
        // which would stretch the file and break the alignment with the microphone.
        guard type == .screen || CMSampleBufferGetPresentationTimeStamp(buffer) >= startTime else { return }
        switch type {
        case .audio:
            system?.append(buffer)
            peakSystem = max(peakSystem, Self.peak(of: buffer))
        case .microphone:
            mic?.append(buffer)
            peakMic = max(peakMic, Self.peak(of: buffer))
        default:
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastLevelPush) > 0.1 {
            lastLevelPush = now
            let levels = (peakSystem, peakMic)
            peakSystem = 0
            peakMic = 0
            DispatchQueue.main.async { self.onLevels?(levels.0, levels.1) }
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        let message = error.localizedDescription
        DispatchQueue.main.async { self.onInterrupted?(message) }
    }

    /// Loudest sample in the buffer, 0...1. Only reads 32-bit float audio, which is what the system delivers.
    private static func peak(of buffer: CMSampleBuffer) -> Float {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else { return 0 }
        var peak: Float = 0
        try? buffer.withAudioBufferList { list, _ in
            for audioBuffer in list {
                guard let data = audioBuffer.mData else { continue }
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
                var index = 0
                while index < count {
                    peak = max(peak, abs(samples[index]))
                    index += 8
                }
            }
        }
        return min(peak, 1)
    }
}
