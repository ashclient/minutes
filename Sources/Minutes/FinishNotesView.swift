import SwiftUI

@MainActor struct FinishNotesView: View {
    @EnvironmentObject var pipeline: MeetingPipeline
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var store: Store
    let id: UUID
    @State private var length: NotesLength = .complete
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("How much detail would you like?").font(.title2).fontWeight(.semibold)
            Text("Your recording is saved. Choose the notes you want to make from it.").foregroundStyle(.secondary)
            ForEach(NotesLength.allCases) { option in
                Button { length = option } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: length == option ? "largecircle.fill.circle" : "circle").foregroundStyle(length == option ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 5) { Text(option.title).fontWeight(.medium); Text(option.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        Spacer(minLength: 0)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(length == option ? 0.07 : 0.025), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain)
            }
            HStack {
                Button("Decide later") { pipeline.finishID = nil }
                Button("Transcript only") { finish(true) }
                Spacer()
                Button("Make notes") { finish(false) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.disabled(pipeline.working)
        }.padding(26).frame(width: 470).onAppear { length = store.meetings.first { $0.id == id }?.notesLength ?? .complete }
    }
    private func finish(_ only: Bool) { pipeline.finish(id: id, length: length, transcriptOnly: only, store: store, recorder: recorder) }
}
