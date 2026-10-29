import SwiftUI

@MainActor struct FinishNotesView: View {
    @EnvironmentObject var pipeline: MeetingPipeline
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var store: Store
    let id: UUID
    @State private var length: NotesLength = .complete
    @State private var step = 0
    @State private var transcriptOnly = false
    @State private var mode: NotionDeliveryMode = .local
    @State private var selectedPage: NotionPageChoice?
    @State private var working = false
    @State private var message = ""
    private var connected: Bool { UserDefaults.standard.bool(forKey: "notionEnabled") || ProcessInfo.processInfo.arguments.contains("--preview-delivery") }
    private var meeting: Meeting? { store.meetings.first { $0.id == id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(step == 0 ? "How much detail would you like?" : "Where should the notes go?").font(.title2).fontWeight(.semibold); Spacer(); Text("\(step + 1) of 2").font(.caption).foregroundStyle(.secondary) }
            if step == 0 {
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
                    Button("Transcript only") { transcriptOnly = true; step = 1 }
                    Spacer()
                    Button("Next") { transcriptOnly = false; step = 1 }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }.disabled(pipeline.working)
            } else {
                Text("A local copy is always saved. Notion sync is optional for this meeting.").font(.callout).foregroundStyle(.secondary)
                Picker("Save to", selection: $mode) {
                    Text(NotionDeliveryMode.local.title).tag(NotionDeliveryMode.local)
                    if connected {
                        Text(NotionDeliveryMode.newPage.title).tag(NotionDeliveryMode.newPage)
                        if meeting?.notionPageID != nil { Text(NotionDeliveryMode.linked.title).tag(NotionDeliveryMode.linked) }
                        Text(NotionDeliveryMode.existing.title).tag(NotionDeliveryMode.existing)
                    }
                }.pickerStyle(.radioGroup).labelsHidden()
                if mode == .existing { NotionPagePicker(selection: $selectedPage) }
                else if mode == .newPage { Text("New page in " + (UserDefaults.standard.string(forKey: "notionDestinationTitle") ?? "your configured Notion destination") + ".").font(.callout).foregroundStyle(.secondary) }
                else if mode == .linked { Text("Updates only this meeting’s notes on its linked page.").font(.callout).foregroundStyle(.secondary) }
                else { Text(connected ? "This meeting won’t be sent to Notion." : "Connect Notion in Settings whenever you want to sync notes.").font(.callout).foregroundStyle(.secondary) }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
                HStack { Button("Back") { step = 0 }; Spacer(); Button(working ? "Checking page…" : transcriptOnly ? "Save transcript" : "Make notes") { Task { await finish() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(working || pipeline.working || (mode == .existing && selectedPage == nil)) }
            }
        }.padding(26).frame(width: 490).onAppear {
            length = meeting?.notesLength ?? .complete
            mode = connected ? (meeting?.notionPageID == nil ? .newPage : .linked) : .local
            if ProcessInfo.processInfo.arguments.contains("--preview-delivery") { step = 1; mode = .existing }
        }
    }
    private func finish() async {
        working = true; message = ""; defer { working = false }
        do {
            var page = selectedPage
            if mode == .existing {
                guard let selectedPage else { return }
                let object = try await NotionClient(token: CloudKey.read(service: "notion")).call("pages/" + selectedPage.id)
                guard let verified = NotionPageChoice.parse(object) else { throw AppFailure("That page is unavailable. Choose another page.") }; page = verified
            }
            store.update(id) { NotionDelivery.apply(mode: mode, page: page, to: &$0) }
            pipeline.finish(id: id, length: length, transcriptOnly: transcriptOnly, store: store, recorder: recorder)
        } catch { message = error.localizedDescription }
    }
}
