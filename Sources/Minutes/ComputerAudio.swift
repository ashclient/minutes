import AVFoundation
import ScreenCaptureKit
import CoreMedia

// ScreenCaptureKit delivers system PCM directly, independently of microphone input.
// Stream callbacks and sink creation are serialized on queue; snapshots/gates use lock.
final class ComputerAudio: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Minutes.computer-audio", qos: .userInitiated)
    private let lock = NSLock()
    private var stream: SCStream?
    @MainActor private var shutdown: Task<Void, Error>?
    private var sink: MicrophoneSink?
    private var destination: URL?
    private var feed: SpeechFeed?
    private var paused = false
    private var failure: String?
    private var frames = 0
    var hasFrames: Bool { (feed?.receivedSeconds ?? 0) > 0 }
    var status: (Float, String?, Int) {
        lock.lock(); let sink = sink; let failure = failure; let frames = frames; lock.unlock()
        let state = sink?.status ?? (0, nil)
        return (state.0, failure ?? state.1, frames)
    }
    func setPaused(_ value: Bool) {
        lock.lock(); paused = value; sink?.setGate(paused: value, muted: false); lock.unlock()
    }
    private func fail(_ text: String) { lock.lock(); failure = text; lock.unlock() }
    func start(url: URL, feed: SpeechFeed) async throws {
        destination = url; self.feed = feed
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw AppFailure("No display is available for system audio capture.") }
        let config = SCStreamConfiguration()
        config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true; config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000; config.channelCount = 2
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }
    // Kept separate so PCM extraction can be tested without screen/microphone permission.
    static func pcm(from sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard CMSampleBufferDataIsReady(sample), let description = CMSampleBufferGetFormatDescription(sample), CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio else { throw AppFailure("Computer audio arrived in an unreadable format.") }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { throw AppFailure("Could not allocate computer audio.") }
        buffer.frameLength = AVAudioFrameCount(count)
        let code = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList)
        guard code == noErr else { throw AppFailure("Computer PCM could not be copied (\(code)).") }
        return buffer
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) > 0 else { return }
        do {
            let buffer = try Self.pcm(from: sample)
            if sink == nil {
                guard let destination, let feed else { return }
                let next = try MicrophoneSink(url: destination, format: buffer.format, feed: feed)
                lock.lock(); next.setGate(paused: paused, muted: false); sink = next; lock.unlock()
            }
            sink?.append(buffer)
            lock.lock(); frames += Int(buffer.frameLength); lock.unlock()
        } catch { fail(error.localizedDescription) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { fail(error.localizedDescription) }
    @MainActor func stop() async throws {
        if let shutdown { return try await shutdown.value }
        let task = Task { try await self.stopOnce() }; shutdown = task
        try await task.value
    }
    private func stopOnce() async throws {
        var stopError: Error?
        do { try await stream?.stopCapture() } catch { stopError = error }
        stream = nil
        // Drain callbacks before closing the file and ending the speech stream.
        let captured: MicrophoneSink? = await withCheckedContinuation { c in queue.async { c.resume(returning: self.sink) } }
        await captured?.finish()
        if let stopError { throw stopError }
        if let error = status.1 { throw AppFailure(error) }
    }
}

