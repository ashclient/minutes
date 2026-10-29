import XCTest
@testable import Minutes

@MainActor private final class SyntheticAppleInference: AppleNoteInference {
    var active = 0, maximum = 0
    var keys: [String] = []
    var evidenceFinished = false
    func generate(_ text: String, instruction: String, tokens: Int, key: String, partial: @escaping @MainActor (String) -> Void) async throws -> String {
        keys.append(key); active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        try await Task.sleep(nanoseconds: 3_000_000)
        let result: String
        if key.hasPrefix("ledger") {
            result = "## Recognition\n- Recognize revenue when the required condition is met.\n\n## Allocation\n- Allocate the price by relative standalone values."
        } else if key.hasPrefix("plan") {
            result = "{\"topics\":[{\"title\":\"Recognition\",\"ids\":[0,2,4,6,8,10,12]},{\"title\":\"Allocation\",\"ids\":[1,3,5,7,9,11,13]}]}"
        } else if key.hasPrefix("write") {
            evidenceFinished = true
            result = instruction.contains("topic “Recognition”") ? "## Recognition\n- Recognize revenue when the required condition is met." : "## Allocation\n- Allocate the price by relative standalone values."
        } else {
            XCTAssertTrue(text.contains("RELEVANT ORIGINAL SOURCE"))
            result = text.contains("COMPLETE TOPIC DRAFT:\n## Recognition") ? "## Recognition\n- Recognize revenue when the condition is met." : "## Allocation\n- Allocate by relative standalone values."
        }
        partial(String(result.prefix(result.count / 2)))
        try await Task.sleep(nanoseconds: 3_000_000)
        partial(result); return result
    }
}
final class CollaborativeEditingTests: XCTestCase {
    @MainActor func testAppleRetainsEvidenceAndPublishesDisjointLiveTopicEdits() async throws {
        let model = SyntheticAppleInference()
        var snapshots: [[LiveNoteSection]] = [], text: [String] = [], activity: [[NoteWorker]] = [], fractions: [Double] = []
        let result = try await AppleNotesAI.compose(String(repeating: "Revenue is recognized when the stated condition is met. Allocation uses standalone values.\n", count: 120), length: .auto, format: .outline, workers: 4, editing: true, infer: model, fraction: { fractions.append($0) }, partial: { text.append($0) }, activity: { activity.append($0) }, sections: { snapshots.append($0) })
        XCTAssertTrue(model.evidenceFinished)
        XCTAssertEqual(model.keys.filter { $0.hasPrefix("plan") }.count, 1)
        XCTAssertEqual(model.keys.filter { $0.hasPrefix("editor") }.count, 2)
        XCTAssertEqual(model.keys.filter { $0.hasPrefix("write") }.count, 2)
        XCTAssertFalse(model.keys.contains { $0.hasPrefix("reduce") })
        XCTAssertLessThanOrEqual(model.maximum, 4); XCTAssertGreaterThan(model.maximum, 1)
        XCTAssertFalse(text.contains { $0.contains("INTERNAL_EVIDENCE_ONLY") })
        XCTAssertTrue(snapshots.contains { $0.filter { $0.worker != nil }.count == 2 })
        XCTAssertEqual(result.summary.components(separatedBy: "## Recognition").count, 2)
        XCTAssertTrue(result.summary.contains("relative standalone")); XCTAssertFalse(result.summary.contains("Editor"))
        XCTAssertEqual(fractions, fractions.sorted()); XCTAssertEqual(fractions.last, 1)
        XCTAssertEqual(activity.last, [])
    }
    @MainActor func testWorkerPoolClampsToFourAndRetainsSourceOrder() async throws {
        var active = 0, maximum = 0, seen: [[NoteWorker]] = []
        let values = try await NoteWorkerPool.map(Array(0..<12), limit: 99, activity: { seen.append($0) }, label: { "Passage \($0)" }) { _, index, value in
            active += 1; maximum = max(maximum, active); defer { active -= 1 }
            try await Task.sleep(nanoseconds: UInt64(12 - index) * 1_000_000)
            return value * 2
        }
        XCTAssertEqual(values, (0..<12).map { $0 * 2 }); XCTAssertEqual(maximum, 4)
        XCTAssertEqual(seen.last, []); XCTAssertTrue(seen.allSatisfy { Set($0.map(\.id)).count == $0.count })
    }
    @MainActor func testCancellationStopsWorkersAndClearsActivity() async throws {
        var latest: [NoteWorker] = [], started = 0
        let task = Task {
            try await NoteWorkerPool.map(Array(0..<20), limit: 4, activity: { latest = $0 }, label: { String($0) }) { _, _, value in
                started += 1
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return value
            }
        }
        for _ in 0..<100 { if started == 4 { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must not produce completed notes") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(started, 4); XCTAssertTrue(latest.isEmpty)
    }
    @MainActor func testSingleWorkerAndEditingOffUseOneWholeDocumentForEveryLength() async throws {
        for length in NotesLength.allCases {
            let model = SyntheticAppleInference()
            _ = try await AppleNotesAI.compose("A source condition and relative standalone prices.", length: length, format: .outline, workers: 1, editing: false, infer: model)
            XCTAssertEqual(model.maximum, 1); XCTAssertEqual(model.keys.filter { $0.hasPrefix("plan") }.count, 1)
            XCTAssertFalse(model.keys.contains { $0.hasPrefix("editor") })
        }
    }
    @MainActor func testConcurrentTopicUpdatesKeepStableIdsAndOtherTopics() {
        var snapshots: [[LiveNoteSection]] = []
        let document = CollaborativeDraft(text: "## First\n- Original first.\n\n## Second\n- Original second.") { values, _ in snapshots.append(values) }
        let ids = document.sections.map(\.id)
        document.update(index: 1, value: "## Second\n- Revised second.", worker: 2)
        document.update(index: 0, value: "## First\n- Revised first.", worker: 1)
        XCTAssertEqual(document.sections.map(\.id), ids)
        XCTAssertTrue(document.text.contains("Revised first")); XCTAssertTrue(document.text.contains("Revised second"))
        XCTAssertEqual(snapshots.last?.map(\.worker), [1, 2])
    }
    func testMiddleReplacementsAndDeletionAnimateWithoutRemovingUntouchedSuffix() {
        var reveal = DraftReveal()
        reveal.update("Beginning old words ending 👨‍👩‍👧‍👦", immediate: true)
        reveal.update("Beginning new ending 👨‍👩‍👧‍👦")
        XCTAssertEqual(reveal.visible, "Beginning old words ending 👨‍👩‍👧‍👦")
        XCTAssertFalse(reveal.removedPreview.isEmpty)
        for _ in 0..<150 {
            reveal.tick(); XCTAssertTrue(reveal.visible.hasSuffix("ending 👨‍👩‍👧‍👦"))
        }
        XCTAssertEqual(reveal.visible, "Beginning new ending 👨‍👩‍👧‍👦")
        reveal.update("Beginning ending 👨‍👩‍👧‍👦")
        for _ in 0..<150 { reveal.tick() }
        XCTAssertEqual(reveal.visible, "Beginning ending 👨‍👩‍👧‍👦")
    }
    func testRapidRetargetingConvergesAndReduceMotionIsImmediate() {
        var reveal = DraftReveal(); reveal.update("Alpha original omega", immediate: true)
        for value in ["Alpha one omega", "Alpha two omega", "Alpha final 👋 omega"] { reveal.update(value); reveal.tick() }
        for _ in 0..<150 { reveal.tick() }
        XCTAssertEqual(reveal.visible, "Alpha final 👋 omega")
        reveal.update("Immediate", immediate: true)
        XCTAssertEqual(reveal.visible, "Immediate"); XCTAssertTrue(reveal.removedPreview.isEmpty)
    }
    func testContinuousRetargetingDoesNotStarveDeletionAnimation() {
        var reveal = DraftReveal(); let original = "## Topic\n" + String(repeating: "Old detail. ", count: 30)
        reveal.update(original, immediate: true)
        for index in 1...20 {
            reveal.update("## Topic\nNew concise detail " + String(repeating: ".", count: index))
            reveal.tick(); reveal.tick()
        }
        XCTAssertNotEqual(reveal.visible, original)
        for _ in 0..<150 { reveal.tick() }
        XCTAssertEqual(reveal.visible, "## Topic\nNew concise detail " + String(repeating: ".", count: 20))
    }
    func testEvidenceSelectionIsBoundedAndComesFromActualSource() {
        let source = "Unrelated weather discussion.\n" + String(repeating: "Unrelated chatter. ", count: 90) + "\nAllocation uses relative standalone prices: 360 and 240."
        let excerpt = NoteEvidence.excerpts(for: "Allocation standalone prices", source: source, limit: 1800)
        XCTAssertLessThanOrEqual(excerpt.utf8.count, 1800)
        XCTAssertTrue(excerpt.contains("360 and 240"))
    }
}
