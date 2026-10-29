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
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .background(Color.primary.opacity(enabled && (hovered || configuration.isPressed) ? (configuration.isPressed ? 0.12 : 0.065) : 0), in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(enabled && hovered ? 0.09 : 0), lineWidth: 1).allowsHitTesting(false) }
                .opacity(enabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
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

// Feedback for controls whose label already defines an exact size (timeline
// events and recorder controls). No extra padding or scaling can alter hit areas.
struct SurfaceButtonStyle: ButtonStyle {
    var radius: CGFloat = 6
    func makeBody(configuration: Configuration) -> some View { Surface(configuration: configuration, radius: radius) }
    private struct Surface: View {
        let configuration: Configuration
        let radius: CGFloat
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false
        var body: some View {
            configuration.label
                .contentShape(RoundedRectangle(cornerRadius: radius))
                .overlay {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(Color.primary.opacity(enabled && (hovered || configuration.isPressed) ? (configuration.isPressed ? 0.12 : 0.055) : 0))
                        .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(Color.primary.opacity(enabled && hovered ? 0.13 : 0), lineWidth: 1) }
                        .allowsHitTesting(false)
                }
                .opacity(enabled ? 1 : 0.4)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovered = $0 }
        }
    }
}
