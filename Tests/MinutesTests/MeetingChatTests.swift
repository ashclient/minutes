import XCTest
@testable import Minutes

final class MeetingChatTests: XCTestCase {
    func testOldMeetingsDecodeWithoutChat() throws {
        let source = try JSONEncoder().encode(Meeting())
        var object = try JSONSerialization.jsonObject(with: source) as! [String: Any]
        object.removeValue(forKey: "chatMessages")
        let old = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.chatMessages)
    }
    func testChatRoundTripDoesNotChangeExportedNotes() throws {
        var meeting = Meeting(); meeting.notes = "Personal notes"
        let before = meeting.markdown
        meeting.chatMessages = [MeetingChatMessage(role: "user", text: "What happened?"), MeetingChatMessage(role: "assistant", text: "Captured answer", context: "[01:20]")]
        XCTAssertEqual(try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting)), meeting)
        XCTAssertEqual(meeting.markdown, before)
    }
    func testRetrievalKeepsEarlierRelevantTopicAndLatestSpeechWithinLocalBudget() {
        var meeting = Meeting()
        meeting.transcript = (0..<500).map { TranscriptLine(seconds: Double($0 * 10), source: "Mic", text: $0 == 20 ? "FIFO uses the oldest inventory layer first." : "Other unrelated teaching passage number \($0).") }
        meeting.transcript.append(TranscriptLine(seconds: 5000, source: "Computer", text: "The instructor just assigned chapter seven."))
        let prompt = MeetingChatContext.prompt(meeting: meeting, question: "How does FIFO work?", local: true)
        XCTAssertTrue(prompt.contains("FIFO uses the oldest inventory layer first."))
        XCTAssertTrue(prompt.contains("chapter seven"))
        XCTAssertTrue(prompt.contains("[03:20]"))
        XCTAssertLessThan(prompt.utf8.count, 3800)
    }
    func testRecentSpeechUsesEndOfLongLiveTranscriptRatherThanItsBeginning() {
        var meeting = Meeting()
        meeting.transcript = [TranscriptLine(seconds: 0, source: "Mic", text: String(repeating: "Old lecture material. ", count: 10000) + "The new homework is chapter nine.")]
        let prompt = MeetingChatContext.prompt(meeting: meeting, question: "What did I just miss?", local: true)
        let recent = prompt.components(separatedBy: "RECENT TRANSCRIPT:").last ?? ""
        XCTAssertTrue(recent.contains("The new homework is chapter nine."))
        XCTAssertTrue(recent.contains("[00:00] Mic:"))
        XCTAssertLessThan(recent.utf8.count, 800)
    }
    func testUnicodeBudgetDoesNotSplitScalars() {
        XCTAssertEqual(MeetingChatContext.prefix("😀éABC", bytes: 5), "😀")
        var meeting = Meeting(); meeting.notes = String(repeating: "你好😀", count: 5000)
        XCTAssertLessThan(MeetingChatContext.prompt(meeting: meeting, question: "What matters?", local: true).utf8.count, 3800)
    }
    @MainActor func testMissingSourceDoesNotSendOrSaveQuestion() throws {
        let old = UserDefaults.standard.object(forKey: "notesAIProvider")
        let enabled = UserDefaults.standard.object(forKey: "nvidiaEnabled")
        defer { UserDefaults.standard.set(old, forKey: "notesAIProvider"); UserDefaults.standard.set(enabled, forKey: "nvidiaEnabled") }
        UserDefaults.standard.set("nvidia", forKey: "notesAIProvider"); UserDefaults.standard.set(true, forKey: "nvidiaEnabled")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root); let id = try XCTUnwrap(store.create())
        let chat = MeetingChat(answer: { _, _, _, _ in XCTFail("No context must not call the provider"); return "" })
        chat.ask("What did I miss?", id: id, store: store, appleBusy: false)
        XCTAssertFalse(chat.busy); XCTAssertNotNil(chat.error)
        XCTAssertNil(store.meetings.first?.chatMessages)
    }
    @MainActor func testReplyBelongsToOriginalMeetingAfterSelectionChanges() async throws {
        let old = UserDefaults.standard.object(forKey: "notesAIProvider")
        let enabled = UserDefaults.standard.object(forKey: "nvidiaEnabled")
        defer { UserDefaults.standard.set(old, forKey: "notesAIProvider"); UserDefaults.standard.set(enabled, forKey: "nvidiaEnabled") }
        UserDefaults.standard.set("nvidia", forKey: "notesAIProvider"); UserDefaults.standard.set(true, forKey: "nvidiaEnabled")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root); let first = try XCTUnwrap(store.create())
        store.update(first) { $0.notes = "Inventory lecture"; $0.notionNeedsSync = false }
        let other = try XCTUnwrap(store.create())
        let chat = MeetingChat(answer: { _, _, _, partial in partial("Inventory"); await Task.yield(); return "Inventory answer" })
        chat.ask("What did I miss?", id: first, store: store, appleBusy: false)
        store.selectedID = other
        for _ in 0..<100 where chat.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(chat.busy)
        XCTAssertEqual(store.meetings.first(where: { $0.id == first })?.chatMessages?.last?.text, "Inventory answer")
        XCTAssertEqual(store.meetings.first(where: { $0.id == first })?.notionNeedsSync, false)
        XCTAssertNil(store.meetings.first(where: { $0.id == other })?.chatMessages)
    }
    @MainActor func testCancelKeepsPartialReplyAndLeavesNotesUntouched() async throws {
        let old = UserDefaults.standard.object(forKey: "notesAIProvider")
        let enabled = UserDefaults.standard.object(forKey: "nvidiaEnabled")
        defer { UserDefaults.standard.set(old, forKey: "notesAIProvider"); UserDefaults.standard.set(enabled, forKey: "nvidiaEnabled") }
        UserDefaults.standard.set("nvidia", forKey: "notesAIProvider"); UserDefaults.standard.set(true, forKey: "nvidiaEnabled")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root); let id = try XCTUnwrap(store.create())
        store.update(id) { $0.notes = "Original"; $0.summary = "Existing summary" }
        let chat = MeetingChat(answer: { _, _, _, partial in partial("Partial reply"); try await Task.sleep(nanoseconds: 5_000_000_000); return "Unexpected" })
        chat.ask("What happened?", id: id, store: store, appleBusy: false)
        for _ in 0..<100 where chat.draft.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        chat.cancel()
        for _ in 0..<100 where chat.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        let meeting = try XCTUnwrap(store.meetings.first)
        XCTAssertEqual(meeting.chatMessages?.last?.text, "Partial reply")
        XCTAssertTrue(meeting.chatMessages?.last?.context?.contains("Partial") == true)
        XCTAssertEqual(meeting.notes, "Original"); XCTAssertEqual(meeting.summary, "Existing summary")
    }
}
