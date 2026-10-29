import XCTest
@testable import Minutes
final class PersonalNoteStyleTests: XCTestCase {
    func testSubheadingsAndIndentedDetailsSurviveConsolidation() {
        let source = "## Topic\n### Subtopic\n- Main point\n  - Supporting detail\n  1. First step"
        let result = LectureNotes.organize([source])
        XCTAssertTrue(result.contains("### Subtopic")); XCTAssertTrue(result.contains("\n  - Supporting detail"))
        XCTAssertTrue(result.contains("\n  1. First step"))
    }
    func testNestedNotionListsRetainParentAndNumberedSteps() throws {
        let blocks = NotionMarkdown.blocks("## Transaction\n- Accounts affected\n  - Inventory\n  - Cash\n- Process\n  1. Identify accounts\n  2. Check balance\n## Next topic\n- Another point")
        XCTAssertEqual(blocks.count, 5)
        let accounts = try XCTUnwrap(blocks[1]["bulleted_list_item"] as? [String: Any])
        let children = try XCTUnwrap(accounts["children"] as? [[String: Any]])
        XCTAssertEqual(children.count, 2)
        let process = try XCTUnwrap(blocks[2]["bulleted_list_item"] as? [String: Any])
        let steps = try XCTUnwrap(process["children"] as? [[String: Any]])
        XCTAssertEqual(steps.map { $0["type"] as? String }, ["numbered_list_item", "numbered_list_item"])
    }
    func testDifferentWorkedExamplesKeepRepeatedAccountEffectsAndSteps() {
        let source = "## Accrued expenses\n### Wages\nA company owes employees for work already done.\n- Assets: no change\n1. Identify the liability.\n2. Record the expense.\n### Taxes\nThe company owes taxes to be paid later.\n- Assets: no change\n1. Identify the liability.\n2. Record the expense."
        let result = LectureNotes.organize([source])
        XCTAssertEqual(result.components(separatedBy: "- Assets: no change").count - 1, 2)
        XCTAssertEqual(result.components(separatedBy: "1. Identify the liability.").count - 1, 2)
        XCTAssertTrue(result.contains("A company owes employees"))
        XCTAssertTrue(result.contains("The company owes taxes"))
        let nested = LectureNotes.organize(["## Effects\n- Wages scenario\n  - Cash: no change\n- Tax scenario\n  - Cash: no change"])
        XCTAssertEqual(nested.components(separatedBy: "  - Cash: no change").count - 1, 2)
    }
    func testMixedClassNotesExportAsNativeParagraphsListsAndEquations() throws {
        let note = LectureNotes.organize(["## A relationship\nA short explanation belongs in a paragraph.\n### Worked example\n- Let t be elapsed time in hours.\n- Let d be distance in miles.\n1. Identify the quantities.\n2. Substitute the supplied rate.\n$$\nd = rt\n$$\nThe result describes distance after t hours."])
        let blocks = NotionMarkdown.blocks(note)
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["heading_2", "paragraph", "heading_3", "bulleted_list_item", "bulleted_list_item", "numbered_list_item", "numbered_list_item", "equation", "paragraph"])
        let equation = try XCTUnwrap(blocks[7]["equation"] as? [String: String])
        XCTAssertEqual(equation["expression"], "d = rt")
    }

}
