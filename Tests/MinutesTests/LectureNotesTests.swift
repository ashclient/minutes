import XCTest
@testable import Minutes

final class LectureNotesTests: XCTestCase {
    func testRepeatedTopicsAreCombinedWithoutLosingDifferentCalculations() {
        let result = LectureNotes.organize(["## Revenue\n- Recognize when earned.\n## Inventory\n- Cost: $3,000.", "## Revenue\n- Recognize when earned.\n- Cash received: $4,500."])
        XCTAssertEqual(result.components(separatedBy: "## Revenue").count, 2)
        XCTAssertEqual(result.components(separatedBy: "- Recognize when earned.").count, 2)
        XCTAssertTrue(result.contains("$3,000")); XCTAssertTrue(result.contains("$4,500"))
    }
    @MainActor func testRevertKeepsPreviousNotesAndKeepCommitsOnlyDraft() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(root: folder); let id = try XCTUnwrap(store.create())
        store.update(id) { $0.summary = "Previous notes"; $0.notes = "Custom notes"; $0.transcript = [TranscriptLine(seconds: 0, source: "Microphone", text: "Source")] }
        let pipeline = MeetingPipeline()
        pipeline.liveDraft = "Partial notes"; pipeline.draftDecisionID = id
        pipeline.resolveDraft(keep: false, store: store)
        XCTAssertEqual(store.meetings.first?.summary, "Previous notes")
        pipeline.liveDraft = "Partial notes"; pipeline.draftDecisionID = id
        pipeline.resolveDraft(keep: true, store: store)
        XCTAssertEqual(store.meetings.first?.summary, "Partial notes")
        XCTAssertEqual(store.meetings.first?.notes, "Custom notes")
        XCTAssertEqual(store.meetings.first?.transcript.first?.text, "Source")
        XCTAssertNil(pipeline.draftDecisionID); XCTAssertTrue(pipeline.liveDraft.isEmpty)
    }
}
