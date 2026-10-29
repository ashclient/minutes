import SwiftUI

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Feedback(configuration: configuration) }
    private struct Feedback: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false
        var body: some View {
            configuration.label
                .padding(.horizontal, 4).padding(.vertical, 3)
                .background(Color.primary.opacity(enabled && (hovered || configuration.isPressed) ? (configuration.isPressed ? 0.12 : 0.065) : 0), in: RoundedRectangle(cornerRadius: 6))
                .opacity(enabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

struct ActivityPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        Image(systemName: "waveform").foregroundStyle(.secondary)
            .opacity(pulse ? 1 : 0.35)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}
