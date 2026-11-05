import SwiftUI

@MainActor struct MeetingChatView: View {
    let id: UUID
    let close: () -> Void
    @EnvironmentObject var store: Store
    @EnvironmentObject var chat: MeetingChat
    @EnvironmentObject var pipeline: MeetingPipeline
    @State private var question = ""
    @State private var clear = false
    private var meeting: Meeting? { store.meetings.first { $0.id == id } }
    private var messages: [MeetingChatMessage] { meeting?.chatMessages ?? [] }
    private var answering: Bool { chat.activeID == id }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ask this meeting").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { clear = true } label: { Image(systemName: "trash") }.help("Clear this meeting’s chat").accessibilityLabel("Clear chat").disabled(messages.isEmpty || chat.busy)
                Button(action: close) { Image(systemName: "xmark") }.help("Close chat").accessibilityLabel("Close chat")
            }.buttonStyle(QuietButtonStyle()).padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        Text("Answers use selected transcript excerpts and your notes as of the moment you ask. Live transcription can still miss words.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if messages.isEmpty {
                            Text("Missed something?").font(.headline).padding(.top, 20)
                            suggestion("What did I just miss?")
                            suggestion("Explain the last example simply.")
                        }
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message.role == "user" ? "You" : "Minutes").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                if message.role == "user" { Text(message.text).font(.system(size: 14)).textSelection(.enabled) }
                                else {
                                    NoteDocument(text: message.text).equatable()
                                    if let context = message.context { Text(context).font(.system(size: 10)).foregroundStyle(.secondary) }
                                    Button("Add to my notes") {
                                        store.update(id) { $0.notes += ($0.notes.isEmpty ? "" : "\n\n") + message.text }
                                    }.font(.system(size: 11)).buttonStyle(QuietButtonStyle())
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if answering {
                            if chat.draft.isEmpty { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the captured context…").font(.caption).foregroundStyle(.secondary) } }
                            else { NoteDocument(text: chat.draft).equatable() }
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }.padding(16)
                }
                // New turns scroll into view; streaming does not pull readers away
                // from earlier messages they are inspecting.
                .onChange(of: messages.count) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            if chat.errorID == id, let error = chat.error { Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 12) }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                TextField("Ask about what you missed…", text: $question, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...5)
                    .onSubmit { send() }
                    .padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Text(chat.busy && !answering ? "Replying in another meeting" : NotesAIProvider.selected == .apple ? "Apple Intelligence · on this Mac" : "Text sent to \(NotesAIProvider.selected.cloud?.title ?? "AI")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if answering { Button("Stop") { chat.cancel() }.buttonStyle(QuietButtonStyle()) }
                    else {
                        Button(action: send) { Image(systemName: "arrow.up").fontWeight(.semibold).frame(width: 28, height: 28) }
                            .buttonStyle(QuietButtonStyle()).background(Color.primary.opacity(0.06), in: Circle())
                            .disabled(chat.busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || question.utf8.count > 800 || meeting?.trashed == true)
                            .help("Ask the meeting").accessibilityLabel("Send question")
                    }
                }
                if question.utf8.count > 800 { Text("Keep your question under 800 bytes (roughly 150 words).").font(.caption).foregroundStyle(.secondary) }
            }.padding(16)
        }.background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("Clear this meeting’s chat?", isPresented: $clear) {
            Button("Clear chat", role: .destructive) { store.update(id) { $0.chatMessages = nil } }
        } message: { Text("Your transcript and notes are kept.") }
    }
    private func suggestion(_ text: String) -> some View {
        Button(text) { question = text; send() }.font(.system(size: 13)).buttonStyle(QuietButtonStyle()).disabled(chat.busy)
    }
    private func send() {
        guard !chat.busy else { return }
        chat.ask(question, id: id, store: store, appleBusy: pipeline.working)
        if chat.activeID == id { question = "" }
    }
}
