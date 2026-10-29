import SwiftUI

struct ProcessingProgressView: View {
    let message: String
    let fraction: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(message).lineLimit(2); Spacer(); if let fraction { Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit() } }.font(.system(size: 12)).foregroundStyle(.secondary)
            if let fraction { ProgressView(value: fraction).progressViewStyle(.linear).animation(.easeInOut(duration: 0.35), value: fraction) }
            else { ProgressView().progressViewStyle(.linear) }
        }.accessibilityElement(children: .combine)
    }
}
