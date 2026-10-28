import AVFoundation
import SwiftUI
@MainActor final class AVAudioPlayerHolder: ObservableObject {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    @Published private(set) var playing = false
    @Published private(set) var duration = 0.0
    @Published var position = 0.0
    @Published var speed: Float = 1 { didSet { player?.rate = speed } }
    private var loadedURL: URL?
    func load(_ url: URL) throws {
        if loadedURL == url { return }
        stop()
        player = try AVAudioPlayer(contentsOf: url); player?.enableRate = true; player?.rate = speed
        loadedURL = url; duration = player?.duration ?? 0; position = 0
    }
    func play(_ url: URL) throws {
        try load(url)
        if player?.currentTime ?? 0 >= duration - 0.05 { player?.currentTime = 0 }
        guard player?.play() == true else { throw AppFailure("This recording could not be played.") }
        playing = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.position = player.currentTime; self.playing = player.isPlaying
                if !player.isPlaying { self.timer?.invalidate(); self.timer = nil }
            }
        }
    }
    func pause() { player?.pause(); playing = false; timer?.invalidate(); timer = nil }
    func seek(_ value: Double) { player?.currentTime = value; position = value }
    func stop() { timer?.invalidate(); timer = nil; player?.stop(); player = nil; loadedURL = nil; playing = false }
}

@MainActor struct RecordingPlayer: View {
    let url: URL
    let name: String
    @StateObject private var player = AVAudioPlayerHolder()
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Button {
                    do { if player.playing { player.pause() } else { try player.play(url) } }
                    catch { self.error = error.localizedDescription }
                } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 28, height: 28).background(Color.primary.opacity(0.06), in: Circle()) }
                    .buttonStyle(.plain).help(player.playing ? "Pause playback" : "Play recording").accessibilityLabel(player.playing ? "Pause playback" : "Play recording")
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text(name).font(.system(size: 12, weight: .medium)); Spacer(); Text(clock(player.position) + " / " + clock(player.duration)).monospacedDigit().font(.system(size: 10)).foregroundStyle(.secondary) }
                    Slider(value: Binding(get: { min(player.position, max(player.duration, 0.01)) }, set: { player.seek($0) }), in: 0...max(player.duration, 0.01)).controlSize(.mini).accessibilityLabel("Playback position")
                }
                Menu {
                    ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { rate in Button("\(rate.formatted())×") { player.speed = rate } }
                } label: { Text("\(player.speed.formatted())×").font(.caption).frame(width: 30) }.menuStyle(.borderlessButton).fixedSize()
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(.vertical, 8)
        .onAppear { do { try player.load(url) } catch { self.error = error.localizedDescription } }
        .onDisappear { player.stop() }
    }
    private func clock(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}
