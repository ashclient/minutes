import SwiftUI

@MainActor final class RecorderMeters: ObservableObject {
    @Published var elapsed: TimeInterval = 0
    @Published var microphone: Float = 0
    @Published var computer: Float = 0
}
@MainActor struct RecordingClock: View {
    @ObservedObject var meters: RecorderMeters
    var body: some View { Text(String(format: "%02d:%02d", Int(meters.elapsed) / 60, Int(meters.elapsed) % 60)).font(.system(size: 12, weight: .medium, design: .monospaced)) }
}
@MainActor struct RecorderWaveform: View {
    @ObservedObject var meters: RecorderMeters
    let muted: Bool
    let paused: Bool
    var body: some View { AudioWaveform(level: Double(max(muted ? 0 : meters.microphone, meters.computer)), paused: paused) }
}
@MainActor struct RecordingSourceMeters: View {
    @ObservedObject var meters: RecorderMeters
    let muted: Bool
    let computer: Bool
    let input: String
    let status: String
    var body: some View {
        HStack(spacing: 18) {
            meter("Mic", icon: muted ? "mic.slash" : "mic", level: meters.microphone).help(input)
            if computer { meter("Computer", icon: "speaker.wave.2", level: meters.computer).help(status) }
            Spacer(minLength: 0)
        }
    }
    private func meter(_ name: String, icon: String, level: Float) -> some View {
        HStack(spacing: 6) { Image(systemName: icon); Text(name); HStack(spacing: 2) { ForEach(0..<12) { index in Capsule().fill(Double(level) > Double(index) / 12 ? Color.green.opacity(0.8) : Color.primary.opacity(0.1)).frame(width: 3, height: 9) } } }.font(.system(size: 10)).foregroundStyle(.secondary)
    }
}
