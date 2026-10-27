import AVFoundation

// File writes and speech input run on one serial worker. Mutable callback state
// is protected by lock; AVAudioFile is only used on the worker after initialization.
final class MicrophoneSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Minutes.microphone", qos: .userInitiated)
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var accepting = true
    private var pending = 0
    private var signal: Float = 0
    private var voiceFrames = 0.0
    var voicedDuration: Double { lock.lock(); defer { lock.unlock() }; return voiceFrames }
    private var errorText: String?
    private let feed: SpeechFeed
    var status: (Float, String?) { lock.lock(); defer { lock.unlock() }; return (signal, errorText) }
    init(url: URL, format: AVAudioFormat, feed: SpeechFeed) throws {
        self.feed = feed
        file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: Int(format.channelCount), AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        guard pending < 256 else { errorText = "Audio processing could not keep up. Stop and check this recording."; lock.unlock(); return }
        pending += 1; lock.unlock()
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            lock.lock(); pending -= 1; errorText = "Could not allocate an audio buffer."; lock.unlock(); return
        }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in src.indices { if let from = src[i].mData, let to = dst[i].mData { memcpy(to, from, Int(src[i].mDataByteSize)) } }
        var level: Float = 0
        if let floats = buffer.floatChannelData, buffer.frameLength > 0 {
            var squares: Float = 0
            for i in 0..<Int(buffer.frameLength) { squares += floats[0][i] * floats[0][i] }
            level = min(1, sqrt(squares / Float(buffer.frameLength)) * 5)
        }
        lock.lock(); signal = level
        if level > 0.08 { voiceFrames += Double(buffer.frameLength) / buffer.format.sampleRate }
        lock.unlock()
        queue.async {
            do { try self.file?.write(from: copy) } catch { self.lock.lock(); self.errorText = error.localizedDescription; self.lock.unlock() }
            self.feed.append(copy)
            self.lock.lock(); self.pending -= 1; self.lock.unlock()
        }
    }
    private func stopAccepting() { lock.lock(); accepting = false; lock.unlock() }
    private var outstanding: Int { lock.lock(); defer { lock.unlock() }; return pending }
    func finish() async {
        stopAccepting()
        while outstanding > 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        await withCheckedContinuation { c in queue.async { self.file = nil; c.resume() } }
    }
}
@MainActor final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var sink: MicrophoneSink?
    var voicedDuration: Double { sink?.voicedDuration ?? 0 }
    var status: (Float, String?) {
        guard engine.isRunning else { return (0, "Microphone input stopped. Stop recording and check macOS Sound → Input.") }
        return sink?.status ?? (0, nil)
    }
    func start(url: URL, feed: SpeechFeed) throws {
        let input = engine.inputNode; let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AppFailure("No microphone is available. Choose an input in macOS Sound settings.") }
        let sink = try MicrophoneSink(url: url, format: format, feed: feed)
        self.sink = sink
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.append(buffer) }
        do { engine.prepare(); try engine.start() }
        catch { input.removeTap(onBus: 0); throw error }
    }
    func stop() async {
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        await sink?.finish()
    }
}
