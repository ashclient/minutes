import AVFoundation
@MainActor final class AVAudioPlayerHolder {
    private var player: AVAudioPlayer?
    func play(_ url: URL) throws {
        player?.stop()
        player = try AVAudioPlayer(contentsOf: url)
        guard player?.play() == true else { throw AppFailure("This recording could not be played.") }
    }
    func stop() { player?.stop(); player = nil }
}
