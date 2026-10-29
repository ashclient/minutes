import XCTest
@testable import Minutes
final class AutoAndRevealTests: XCTestCase {
    func testAutoHasNoSemanticWordBudgetAndCanRoundTrip() throws {
        XCTAssertEqual(StudyBudget.maximum(.auto), Int.max)
        XCTAssertTrue(NotesLength.auto.instruction.contains("No target length"))
        var note = Meeting(); note.notesLength = .auto
        XCTAssertEqual(try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(note)).notesLength, .auto)
    }
    func testFormulaDelimitersSurviveConsolidationAndDoNotSwallowMarkdown() throws {
        let source = "## Formula\n$$\na = b + c\n$$\n- Explain it\n## Next topic\n- A new point"
        let combined = LectureNotes.organize([source])
        XCTAssertEqual(combined.components(separatedBy: "$$").count, 3)
        let parts = NoteMath.parts(combined)
        XCTAssertEqual(parts.filter(\.equation).map(\.text), ["a = b + c"])
        let malformed = NoteMath.parts("$$\na = b + c\n## Next topic\n- A new point")
        XCTAssertEqual(malformed.filter(\.equation).map(\.text), ["a = b + c"])
        XCTAssertTrue(malformed.contains { !$0.equation && $0.text == "## Next topic" })
    }
    func testRevealUsesActualGraphemesAndHandlesRevisionsAndImmediateStop() {
        var reveal = DraftReveal()
        let value = "Hello 👨‍👩‍👧‍👦 café"
        reveal.update(value)
        XCTAssertTrue(reveal.visible.isEmpty)
        reveal.tick(); XCTAssertFalse(reveal.visible.isEmpty); XCTAssertTrue(value.hasPrefix(reveal.visible))
        for _ in 0..<100 { reveal.tick() }; XCTAssertEqual(reveal.visible, value)
        reveal.update("Revised topic"); XCTAssertEqual(reveal.visible, "Revised topic")
        reveal.update("Revised topic with more text", immediate: true)
        XCTAssertEqual(reveal.visible, "Revised topic with more text")
    }
}
