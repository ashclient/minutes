import Foundation
import SwiftUI

@MainActor final class MeetingChat: ObservableObject {
    @Published private(set) var activeID: UUID?
    @Published private(set) var draft = ""
    @Published private(set) var error: String?
    @Published private(set) var errorID: UUID?
    private var job: Task<Void, Never>?
    typealias Answer = @MainActor (NotesAIProvider, String, String?, @escaping @MainActor (String) -> Void) async throws -> String
    private let answer: Answer
    init(answer: @escaping Answer = MeetingChat.generate) { self.answer = answer }
    static func generate(provider: NotesAIProvider, prompt: String, model: String?, partial: @escaping @MainActor (String) -> Void) async throws -> String {
        if provider == .apple { return try await AppleNotesAI.answerQuestion(prompt, partial: partial) }
        let cloud = provider.cloud ?? .openRouter
        let key = try CloudKey.read(service: cloud.service)
        return try await AIClient(apiKey: key, provider: cloud, model: model).answerQuestion(prompt, partial: partial)
    }
    var busy: Bool { activeID != nil }

    func ask(_ question: String, id: UUID, store: Store, appleBusy: Bool) {
        guard !busy, let meeting = store.meetings.first(where: { $0.id == id }), !meeting.trashed else { return }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.utf8.count <= 800 else { return }
        error = nil; errorID = id
        let provider = NotesAIProvider.selected
        guard provider.configured else { error = "Choose an available AI provider in Settings first."; return }
        guard provider != .apple || (!appleBusy && !AppleNotesAI.chatInProgress) else { error = "Apple Intelligence is finishing notes. Ask again when it finishes, or choose a cloud provider in Settings."; return }
        guard !meeting.transcript.isEmpty || !meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Wait for a few words to be transcribed, or add your own notes first."; return }
        // Snapshot context at send time; incoming audio continues independently.
        activeID = id; draft = ""
        if provider == .apple { AppleNotesAI.chatInProgress = true }
        let cloud = provider.cloud
        let model = cloud?.model
        let providerName = provider == .apple ? "Apple Intelligence" : cloud!.title
        let context = (meeting.transcript.isEmpty ? "Personal notes" : "Transcript snapshot · segment-start timestamps") + " · " + providerName
        store.update(id) { $0.chatMessages = ($0.chatMessages ?? []) + [MeetingChatMessage(role: "user", text: question)] }
        job = Task { [weak self] in
            guard let self else { return }
            defer { if provider == .apple { AppleNotesAI.chatInProgress = false }; self.activeID = nil; self.draft = ""; self.job = nil }
            do {
                let prompt = await Task.detached(priority: .userInitiated) { MeetingChatContext.prompt(meeting: meeting, question: question, local: provider == .apple) }.value
                try Task.checkCancellation()
                let partial: @MainActor (String) -> Void = { [weak self] text in
                    guard !Task.isCancelled else { return }; self?.draft = text
                }
                let answer = try await self.answer(provider, prompt, model, partial)
                try Task.checkCancellation()
                store.update(id) { $0.chatMessages = ($0.chatMessages ?? []) + [MeetingChatMessage(role: "assistant", text: answer, context: context)] }
            } catch {
                if !self.draft.isEmpty {
                    let saved = self.draft
                    store.update(id) { $0.chatMessages = ($0.chatMessages ?? []) + [MeetingChatMessage(role: "assistant", text: saved, context: "Partial reply · stopped before completion")] }
                }
                if !Task.isCancelled { self.error = error.localizedDescription; self.errorID = id }
            }
        }
    }
    func cancel() { job?.cancel() }
    func saveForQuit(store: Store) {
        if let id = activeID, !draft.isEmpty {
            let saved = draft
            store.update(id) { $0.chatMessages = ($0.chatMessages ?? []) + [MeetingChatMessage(role: "assistant", text: saved, context: "Partial reply · app closed")] }
        }
        draft = ""; job?.cancel()
    }
}
