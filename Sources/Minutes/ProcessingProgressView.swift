import SwiftUI

struct ProcessingProgressView: View {
    let message: String
    let fraction: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(message).lineLimit(2); Spacer(); if let fraction { Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit() } }.font(.system(size: 12)).foregroundStyle(.secondary)
            GlintProgressBar(fraction: fraction)
        }.accessibilityElement(children: .combine)
    }
}

// A small, clipped highlight travels only across the filled part of the track.
// TimelineView stops when the view leaves the hierarchy; Reduce Motion is static.
struct GlintProgressBar: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var amount: Double { min(1, max(0, fraction ?? 0.28)) }
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * amount
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(reduceTransparency ? 0.18 : 0.08))
                Capsule().fill(Color.primary.opacity(0.7)).frame(width: width)
                    .overlay(alignment: .leading) {
                        if !reduceMotion && amount > 0 && amount < 1 {
                            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
                                LinearGradient(colors: [.clear, .white.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 64)
                                    .offset(x: (width + 64) * phase - 64)
                            }
                        }
                    }
                    .clipShape(Capsule())
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: amount)
        }
        .frame(height: 5)
        .accessibilityLabel("Progress")
        .accessibilityValue(fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "In progress")
    }
}
