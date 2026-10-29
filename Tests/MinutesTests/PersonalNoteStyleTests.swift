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
}
