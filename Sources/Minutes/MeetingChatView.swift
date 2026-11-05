import SwiftUI

struct FloatingAskButton: View {
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "text.bubble").font(.system(size: 19, weight: .medium))
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.primary.opacity(hovered ? 0.22 : 0.10)))
                .shadow(color: .black.opacity(hovered ? 0.13 : 0.08), radius: hovered ? 12 : 7, y: 3)
                .contentShape(RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .help("Ask this meeting · ⌘J").accessibilityLabel("Ask this meeting")
            .keyboardShortcut("j", modifiers: .command)
    }
}

@MainActor struct MeetingChatView: View {
    let id: UUID
    let close: () -> Void
    @EnvironmentObject var store: Store
    @EnvironmentObject var chat: MeetingChat
    @EnvironmentObject var pipeline: MeetingPipeline
    @State private var question = ""
    @State private var clear = false
    @FocusState private var composing: Bool
    private var meeting: Meeting? { store.meetings.first { $0.id == id } }
    private var messages: [MeetingChatMessage] { meeting?.chatMessages ?? [] }
    private var answering: Bool { chat.activeID == id }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble").font(.system(size: 16))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Meeting assistant").font(.system(size: 13, weight: .semibold))
                    Text(meeting?.title ?? "This meeting").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if !messages.isEmpty {
                    Button { clear = true } label: { Image(systemName: "trash").font(.system(size: 12)) }
                        .help("Clear this meeting’s chat").accessibilityLabel("Clear chat").disabled(chat.busy)
                }
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 12)) }
                    .help("Close assistant · ⌘J").accessibilityLabel("Close chat").keyboardShortcut("j", modifiers: .command)
            }.buttonStyle(QuietButtonStyle()).padding(18)
            Divider().opacity(0.6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if messages.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Pick up where you left off.").font(.system(size: 21, weight: .semibold))
                                Text("Ask about something you missed, or work through a tricky explanation.")
                                    .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                            }.padding(.top, 24).padding(.bottom, 10)
                            VStack(spacing: 8) {
                                suggestion("Catch me up", detail: "What did I just miss?")
                                suggestion("Explain the last example", detail: "Explain the last example simply.")
                                suggestion("Pull out the key points", detail: "What are the most important points from the recent discussion?")
                            }
                            Text("Uses captured transcript excerpts and your notes. It can’t recover words that weren’t transcribed.")
                                .font(.system(size: 11)).foregroundStyle(.tertiary).lineSpacing(3).padding(.top, 4)
                        }
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 9) {
                                if message.role == "user" {
                                    Text(message.text).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                                } else {
                                    NoteDocument(text: message.text).equatable()
                                    if let context = message.context { Text(context).font(.system(size: 10)).foregroundStyle(.tertiary) }
                                    Button { store.update(id) { $0.notes += ($0.notes.isEmpty ? "" : "\n\n") + message.text } } label: {
                                        Label("Add to notes", systemImage: "plus")
                                    }.font(.system(size: 11)).buttonStyle(QuietButtonStyle()).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if answering {
                            if chat.draft.isEmpty {
                                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the meeting…").font(.system(size: 12)).foregroundStyle(.secondary) }
                            } else { NoteDocument(text: chat.draft).equatable() }
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }.padding(.horizontal, 20).padding(.bottom, 20)
                }
                .onChange(of: messages.count) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            if chat.errorID == id, let error = chat.error {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 12)
            }
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 10) {
                    TextField("Ask about this meeting…", text: $question, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(2...6).focused($composing).onSubmit { send() }
                    HStack {
                        Text(chat.busy && !answering ? "Replying in another meeting" : NotesAIProvider.selected == .apple ? "On this Mac" : NotesAIProvider.selected.cloud?.title ?? "AI")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        if answering { Button("Stop") { chat.cancel() }.buttonStyle(QuietButtonStyle()).font(.system(size: 12)) }
                        else {
                            Button(action: send) {
                                Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
                            }.buttonStyle(QuietButtonStyle()).background(Color.primary.opacity(0.07), in: Circle())
                                .disabled(chat.busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || question.utf8.count > 800 || meeting?.trashed == true)
                                .help("Ask the meeting").accessibilityLabel("Send question")
                        }
                    }
                }.padding(12).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(composing ? 0.22 : 0.10)))
                if question.utf8.count > 800 { Text("Try a shorter question.").font(.caption).foregroundStyle(.secondary) }
                Text(NotesAIProvider.selected == .apple ? "Replies use Apple Intelligence on your Mac." : "Questions and selected context are sent to your AI provider.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(16)
        }.background(Color(nsColor: .windowBackgroundColor))
            .onAppear { composing = true }
            .confirmationDialog("Clear this meeting’s chat?", isPresented: $clear) {
                Button("Clear chat", role: .destructive) { store.update(id) { $0.chatMessages = nil } }
            } message: { Text("Your transcript and notes are kept.") }
    }
    private func suggestion(_ title: String, detail: String) -> some View {
        Button { question = detail; send() } label: {
            HStack { Text(title); Spacer(); Image(systemName: "arrow.up.left").font(.system(size: 10)).foregroundStyle(.tertiary) }
                .font(.system(size: 12)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.055)))
        }.buttonStyle(QuietButtonStyle()).disabled(chat.busy)
    }
    private func send() {
        guard !chat.busy else { return }
        chat.ask(question, id: id, store: store, appleBusy: pipeline.working)
        if chat.activeID == id { question = "" }
    }
}
