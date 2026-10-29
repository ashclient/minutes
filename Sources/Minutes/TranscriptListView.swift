import SwiftUI

struct TranscriptListView: View {
    let lines: [TranscriptLine]
    @State private var visibleCount = 200
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if lines.count > visibleCount {
                Button("Show 200 earlier segments (\(lines.count - visibleCount) more)") { visibleCount += 200 }.font(.caption)
            }
            if lines.isEmpty { Text("Listening…").font(.callout).foregroundStyle(.secondary) }
            ForEach(lines.suffix(visibleCount)) { line in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) { Text(line.source).fontWeight(.medium); Text(line.timestamp).monospacedDigit().foregroundStyle(.tertiary) }.font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(line.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.top, 14)
    }
}
