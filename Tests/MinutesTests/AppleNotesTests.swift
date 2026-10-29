import XCTest
@testable import Minutes

final class AppleNotesTests: XCTestCase {
    func testExperimentalAppleGateRequiresNewOSAndReadyEligibleModel() {
        XCTAssertFalse(AppleAIAvailability.evaluate(major: 26, eligible: true, enabled: true, ready: true).available)
        XCTAssertFalse(AppleAIAvailability.evaluate(major: 27, eligible: false, enabled: true, ready: true).available)
        XCTAssertFalse(AppleAIAvailability.evaluate(major: 27, eligible: true, enabled: false, ready: true).available)
        XCTAssertFalse(AppleAIAvailability.evaluate(major: 27, eligible: true, enabled: true, ready: false).available)
        XCTAssertTrue(AppleAIAvailability.evaluate(major: 27, eligible: true, enabled: true, ready: true).available)
        XCTAssertTrue(AppleAIAvailability.evaluate(major: 28, eligible: true, enabled: true, ready: true).available)
    }
    func testAppleChunkBudgetKeepsEveryUnicodeScalarAndBoundsUTF8() {
        let text = String(repeating: "講義 🎙️ café words 👨‍👩‍👧‍👦\n", count: 700)
        let pieces = AppleTextBudget.chunks(text)
        XCTAssertEqual(pieces.joined(), text)
        XCTAssertTrue(pieces.allSatisfy { !$0.isEmpty && $0.utf8.count <= 2200 })
        XCTAssertEqual(AppleTextBudget.chunks(""), [])
        XCTAssertEqual(AppleTextBudget.chunks("hello", bytes: 3), [])
    }
    func testNotionPagePickerReadsBothTitleFormatsAndSkipsTrash() {
        let current: [String: Any] = ["object": "page", "id": "page-a", "properties": ["Name": ["type": "title", "title": [["plain_text": "Meeting notes"]]]]]
        XCTAssertEqual(NotionPageChoice.parse(current)?.title, "Meeting notes")
        let old: [String: Any] = ["object": "page", "id": "page-b", "properties": ["title": ["type": "title", "title": [["text": ["content": "Classes"]]]]]]
        XCTAssertEqual(NotionPageChoice.parse(old)?.title, "Classes")
        var deleted = current; deleted["in_trash"] = true
        XCTAssertNil(NotionPageChoice.parse(deleted))
        XCTAssertNil(NotionPageChoice.parse(["object": "database", "id": "db"]))
    }
    @MainActor func testAppleSelectionOnOldMacDoesNotRequestACloudKey() async throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 else { throw XCTSkip("This check exercises the older-macOS gate.") }
        let defaults = UserDefaults.standard; let previous = defaults.object(forKey: "notesAIProvider")
        defaults.set("apple", forKey: "notesAIProvider")
        defer { if let previous { defaults.set(previous, forKey: "notesAIProvider") } else { defaults.removeObject(forKey: "notesAIProvider") } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(root: folder); let id = try XCTUnwrap(store.create())
        store.update(id) { $0.notes = "We agreed to review the draft on Friday." }
        let pipeline = MeetingPipeline(); pipeline.resume(id: id, store: store, recorder: Recorder())
        for _ in 0..<100 { if !pipeline.working { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.meetings.first?.pipelineStatus, "failed")
        XCTAssertTrue(store.meetings.first?.pipelineError?.contains("macOS 27") == true)
        XCTAssertEqual(store.meetings.first?.notes, "We agreed to review the draft on Friday.")
    }
}

final class AppleWorkingDraftTests: XCTestCase {
    @MainActor func testEveryLengthShowsFirstProvisionalConcept() {
        for length in NotesLength.allCases {
            let draft = AppleNotesAI.workingDraft([], pending: "## Core concept\n- A definition with its necessary condition.", length: length)
            XCTAssertTrue(draft.contains("necessary condition"), length.rawValue)
        }
    }
    @MainActor func testDraftKeepsCompletedTopicsAndRespectsBriefBudget() {
        let prior = "## Prior topic\n- A meaningful definition."
        let pending = "## Current topic\n" + (0..<400).map { "- Important concept \($0) with a necessary condition." }.joined(separator: "\n")
        let draft = AppleNotesAI.workingDraft([prior], pending: pending, length: .brief)
        XCTAssertTrue(draft.contains("Prior topic")); XCTAssertTrue(draft.contains("Current topic"))
        XCTAssertLessThanOrEqual(StudyBudget.words(draft), 300)
    }
}
