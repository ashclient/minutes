import XCTest
import AppKit
@testable import Minutes

final class NotesEditorTests: XCTestCase {
    @MainActor func testRoundTripHeadingsEmphasisListsAndUnicode() {
        let markdown = "## Composition\nA **function** uses *input*.\n- First 👩🏽‍🎓\n  - Nested detail\n1. Substitute x.\n2. Evaluate.\n\n### Formula\nUse `f(x)` here.\n"
        let rich = NotesEditorFormat.attributed(markdown)
        XCTAssertFalse(rich.string.contains("##")); XCTAssertFalse(rich.string.contains("**"))
        XCTAssertTrue(rich.string.contains("• First"))
        XCTAssertEqual(NotesEditorFormat.markdown(rich), markdown)
    }
    @MainActor func testBoldListContentKeepsItsNativeNotionListRole() {
        let source = "- **Important condition**\n  - *Supporting detail*"
        XCTAssertEqual(NotesEditorFormat.markdown(NotesEditorFormat.attributed(source)), source)
    }
    @MainActor func testListToolbarDoesNotEraseExistingEmphasis() {
        let view = NotesTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        view.textStorage?.setAttributedString(NotesEditorFormat.attributed("**Important** condition"))
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        view.toggleList()
        XCTAssertEqual(NotesEditorFormat.markdown(view.textStorage!), "- **Important** condition")
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        view.toggleList()
        XCTAssertEqual(NotesEditorFormat.markdown(view.textStorage!), "**Important** condition")
    }
    @MainActor func testEmptyAndPlainNotesRemainEditableWithoutInsertingPlaceholder() {
        XCTAssertEqual(NotesEditorFormat.markdown(NotesEditorFormat.attributed("")), "")
        XCTAssertEqual(NotesEditorFormat.markdown(NotesEditorFormat.attributed("Line one\n\nLine three")), "Line one\n\nLine three")
        let view = NotesTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        view.font = .systemFont(ofSize: NotesEditorFormat.bodySize)
        view.typingAttributes = NotesEditorFormat.attributes
        XCTAssertGreaterThanOrEqual(view.font!.pointSize, 16)
        XCTAssertTrue(view.string.isEmpty)
        view.insertText("Hello", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(view.string, "Hello")
    }
    @MainActor func testFormattingSelectedParagraphPreservesOtherParagraphs() {
        let view = NotesTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        view.textStorage?.setAttributedString(NotesEditorFormat.attributed("First paragraph\nSecond paragraph"))
        view.setSelectedRange(NSRange(location: 0, length: 5)); view.setHeading(2)
        XCTAssertEqual(NotesEditorFormat.markdown(view.textStorage!), "## First paragraph\nSecond paragraph")
        view.setSelectedRange(NSRange(location: 16, length: 6)); view.toggleTrait(.boldFontMask)
        XCTAssertEqual(NotesEditorFormat.markdown(view.textStorage!), "## First paragraph\n**Second** paragraph")
    }
    func testInlineMathIsReadableAndNotionUsesNativeEquationsWithoutChangingMoney() throws {
        let text = #"Apply $G \circ F$ then \(f^{-1}(x)\). Costs $500 or $200."#
        let readable = NoteMath.inlineReadable(text)
        XCTAssertTrue(readable.contains("G ∘ F")); XCTAssertTrue(readable.contains("f⁻¹(x)"))
        XCTAssertFalse(readable.contains("$G")); XCTAssertTrue(readable.contains("$500 or $200"))
        let rich = NotionMarkdown.rich(text)
        XCTAssertEqual(rich.filter { $0["type"] as? String == "equation" }.count, 2)
        let plain = rich.compactMap { ($0["text"] as? [String: Any])?["content"] as? String }.joined()
        XCTAssertTrue(plain.contains("$500 or $200"))
    }
    func testNotionPrecalcHierarchyAndNativeInlineMath() {
        let blocks = NotionMarkdown.blocks("## Composition\nAn overview is useful here.\n- **Order matters:** apply \\(F\\), then \\(G\\).\n1. Find the inner result.\n2. Evaluate the outer function.\n## Inverses\nUndo the original operation.")
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["heading_2", "paragraph", "bulleted_list_item", "numbered_list_item", "numbered_list_item", "heading_2", "paragraph"])
    }
    func testBundledDesktopConfigurationWithoutFilePicker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.minutes.oauth", "CFBundleName": "Test", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appendingPathComponent("Contents/Info.plist"))
        let fixture = #"{"installed":{"client_id":"test.apps.googleusercontent.com","token_proxy":"https://auth.example.com/v1/token"}}"#
        try Data(fixture.utf8).write(to: resources.appendingPathComponent("GoogleOAuth.json"))
        let bundle = try XCTUnwrap(Bundle(url: root))
        XCTAssertEqual(GoogleClientConfig.bundled(in: bundle)?.client_id, "test.apps.googleusercontent.com")
        XCTAssertThrowsError(try GoogleClientConfig.imported(Data(#"{"web":{"client_id":"test.apps.googleusercontent.com"}}"#.utf8)))
    }
}
