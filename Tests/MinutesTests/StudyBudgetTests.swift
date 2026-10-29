import XCTest
@testable import Minutes
final class StudyBudgetTests: XCTestCase {
    func testWholeLectureBudgetsAreDifferentAndPreserveFormulaBoundaries() {
        let text = (0..<200).map { "- Topic \($0) has a clear definition and a useful explanation." }.joined(separator: "\n")
        let short = StudyBudget.limit(text, words: StudyBudget.maximum(.brief))
        let medium = StudyBudget.limit(text, words: StudyBudget.maximum(.detailed))
        XCTAssertLessThanOrEqual(StudyBudget.words(short), 300)
        XCTAssertLessThanOrEqual(StudyBudget.words(medium), 900)
        XCTAssertLessThan(StudyBudget.words(short), StudyBudget.words(medium))
        XCTAssertEqual(StudyBudget.limit("$$\na + b = c\n$$", words: 1), "")
    }
    func testLatexIsReadableInAppAndBecomesNativeNotionEquation() throws {
        let input = "## Allocation\n$$\n\\text{Allocated} = \\frac{450}{530} \\times 500\n$$\n- Explanation"
        let parts = NoteMath.parts(input)
        let formula = try XCTUnwrap(parts.first(where: \.equation))
        XCTAssertEqual(NoteMath.readable(formula.text), "Allocated = (450) ÷ (530) × 500")
        let blocks = NotionMarkdown.blocks(input)
        XCTAssertEqual(blocks.compactMap { $0["type"] as? String }, ["heading_2", "equation", "bulleted_list_item"])
        XCTAssertEqual((blocks[1]["equation"] as? [String: String])?["expression"], formula.text)
    }
    func testOldMeetingWithoutFormatDecodesAndDefaultsRemainAvailable() throws {
        let original = Meeting(); let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(original))
        XCTAssertNil(decoded.studyFormat)
        XCTAssertEqual(StudyFormat.allCases.count, 3)
    }
}
