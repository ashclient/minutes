import XCTest
@testable import Minutes

@MainActor private final class CoverageInference: AppleNoteInference {
    var seenSources: [String] = [], written: [String] = [], editsIncomplete = false
    func generate(_ text: String, instruction: String, tokens: Int, key: String, partial: @escaping @MainActor (String) -> Void) async throws -> String {
        try Task.checkCancellation()
        let result: String
        if key.hasPrefix("ledger") {
            seenSources.append(text)
            // Deliberately retain a different marker for every passage, across
            // the start, middle and end of a long synthetic lecture.
            let index = seenSources.count - 1
            result = "## Topic \(index)\n- Coverage marker M\(index): this distinct condition must be retained with its meaning."
        } else if key.hasPrefix("plan") {
            // A broken planner omits everything. The ledger must restore ALL IDs.
            result = "{\"topics\":[]}"
        } else if key.hasPrefix("write") {
            written.append(text); result = text
        } else if editsIncomplete {
            result = "## Topic\nEach purchase forms a distinct layer:\n\n**Total Cost Example**"
        } else { result = text.components(separatedBy: "RELEVANT ORIGINAL SOURCE EXCERPTS:")[0].replacingOccurrences(of: "COMPLETE TOPIC DRAFT:\n", with: "") }
        partial(result); return result
    }
}
final class EvidenceCoverageTests: XCTestCase {
    @MainActor func testLongLectureDoesNotCollapseAllFactsIntoOneSmallGlobalExtract() async throws {
        let model = CoverageInference(); model.editsIncomplete = true
        let source = (0..<30).map { "\($0)| " + String(repeating: "Substantive teaching content with conditions and distinct examples. ", count: 32) }.joined()
        let chunks = AppleTextBudget.chunks(source, bytes: 2400)
        let result = try await AppleNotesAI.compose(source, length: .auto, format: .outline, workers: 4, editing: true, infer: model)
        XCTAssertEqual(model.seenSources.count, chunks.count)
        XCTAssertEqual(model.seenSources.reduce(0) { $0 + $1.utf8.count }, source.utf8.count)
        XCTAssertEqual(model.written.count, LiveNoteSection.split(result.summary).count)
        for index in 0..<model.seenSources.count { XCTAssertTrue(result.summary.contains("M\(index):"), "Lost source passage \(index)") }
        XCTAssertFalse(result.summary.contains("Total Cost Example"))
        XCTAssertTrue(NoteQuality.complete(result.summary))
    }
    func testPlannerCannotLoseDuplicateUnknownOrOmittedEvidenceIds() {
        let cards = (0..<20).map { LectureEvidence(id: $0, title: "Topic \($0)", text: "## Topic \($0)\n- A complete explanation of condition \($0).", sourceIndex: $0) }
        for proposal in ["invalid", "{\"topics\":[]}", "{\"topics\":[{\"title\":\"Merged\",\"ids\":[0,0,1,999]}]}"] {
            let ids = EvidenceLedger.plan(proposal, evidence: cards).flatMap(\.ids)
            XCTAssertEqual(Set(ids), Set(0..<20)); XCTAssertEqual(ids.count, 20)
        }
    }
    func testEvidenceBatchesPreserveAllPayloadsWithoutRecursiveCompression() {
        let cards = (0..<40).map { LectureEvidence(id: $0, title: "T\($0)", text: "## Topic \($0)\n" + String(repeating: "A distinct meaningful condition. ", count: 12), sourceIndex: $0) }
        let batches = EvidenceLedger.batches(cards)
        XCTAssertGreaterThan(batches.count, 1); XCTAssertTrue(batches.allSatisfy { $0.utf8.count <= 2400 })
        let compact: (String) -> String = { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        XCTAssertEqual(compact(batches.joined(separator: " ")), compact(cards.map(\.text).joined(separator: " ")))
    }
    func testDanglingSectionsAndFabricatedQualitativeEquationsAreRejected() {
        for text in ["## Timing\nRevenue is recognized depending on:", "## Layers\nEach purchase forms a layer:\n## Example\n**Total Cost Example**", "## Formula\n$$\na = ", "## Empty"] {
            XCTAssertFalse(NoteQuality.complete(text), text)
        }
        let falseFormula = "## Feasibility\nCost tracking depends on the inventory.\n$$\n\\text{Cost tracking feasibility} = \\text{low inventory volume} + \\text{high specificity}\n$$"
        XCTAssertTrue(NoteQuality.hasQualitativeEquation(falseFormula))
        XCTAssertFalse(NoteQuality.hasQualitativeEquation("## Allocation\n$$\n360 / 600 * 480 = 288\n$$"))
    }
    func testIncompleteResponsesCannotPoisonRetryCache() {
        XCTAssertFalse(NoteQuality.cacheable("## Topic\nThe required event depends on:", tag: "write-v8"))
        XCTAssertFalse(NoteQuality.cacheable("## Topic\n**Unfinished example**", tag: "editor-v8"))
        XCTAssertTrue(NoteQuality.cacheable("## Topic\n- A complete definition with its necessary condition.", tag: "write-v8"))
        XCTAssertTrue(NoteQuality.cacheable("{\"topics\":[]}", tag: "plan-v8"))
        XCTAssertFalse(NoteQuality.cacheable("Unfinished JSON {", tag: "plan-v8"))
    }
    func testReviewerRepliesCannotRewriteTopicsAndPatchesAreLocalized() {
        let original = "## Allocation\n- Total price is 480.\n- The first item receives 288.\n- The second item receives 192."
        XCTAssertTrue(NoteSanityReview.issues("## Rewritten topic\nDifferent notes.", original: original).isEmpty)
        let report = "{\"issues\":[{\"quote\":\"The first item receives 288.\",\"reason\":\"Check this amount against source.\"},{\"quote\":\"a fabricated quote\",\"reason\":\"Invalid.\"}]}"
        let issue = NoteSanityReview.issues(report, original: original)
        XCTAssertEqual(issue.count, 1)
        let updated = NoteSanityReview.patched("{\"replacement\":\"The first item receives 280.\"}", issue: issue[0], original: original)
        XCTAssertTrue(updated?.contains("Total price is 480.") == true)
        XCTAssertTrue(updated?.contains("second item receives 192.") == true)
        XCTAssertNil(NoteSanityReview.patched("## Rewritten document", issue: issue[0], original: original))
        XCTAssertNil(NoteSanityReview.patched("{\"replacement\":\"\n## Another topic\nUnrelated\"}", issue: issue[0], original: original))
    }
    func testReviewJobsCoverLongUnicodeTopicsWithoutSkippingOrClipping() {
        let first = LiveNoteSection(title: "Long", text: "## Long\n" + String(repeating: "A distinct condition 中文 👨‍👩‍👧‍👦 remains important. ", count: 180))
        let second = LiveNoteSection(title: "Last", text: "## Last\n- A late topic must also be checked.")
        let jobs = NoteReviewJob.make([first, second])
        XCTAssertGreaterThan(jobs.count, 3)
        XCTAssertEqual(jobs.filter { $0.sectionIndex == 0 }.map(\.sourcePart).joined(), first.text)
        XCTAssertEqual(jobs.filter { $0.sectionIndex == 1 }.map(\.sourcePart).joined(), second.text)
        XCTAssertTrue(jobs.allSatisfy { $0.context.utf8.count <= 2056 })
        XCTAssertTrue(jobs.filter { $0.part > 1 }.allSatisfy { $0.context.count > $0.sourcePart.count })
    }
    func testInvalidEditorReplyPreservesLastCompleteTopicWithoutWordClipping() {
        let original = "## Inventory\n- The first purchase layer contains 20 units at 5 each.\n- The second layer contains 30 units at 6 each.\n- The method determines which complete layer costs are assigned."
        XCTAssertTrue(NoteQuality.complete(original))
        XCTAssertFalse(NoteQuality.acceptableEdit("## Inventory\nEach purchase forms a distinct layer:", original: original))
        XCTAssertFalse(NoteQuality.acceptableEdit("## Inventory\n- A layer exists.", original: original))
        XCTAssertTrue(NoteQuality.acceptableEdit(original, original: original))
    }
}
