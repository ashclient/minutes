import XCTest
@testable import Minutes

final class NotesQualityTests: XCTestCase {
    func testNotionExportUsesNativeRichBlocksAndPreservesLongNotes() throws {
        let blocks = NotionMarkdown.blocks("## Concept\n- **Revenue** is not *cash*.\n1. Record $25.\n- [x] Review\n```\na = b + 2\n```")
        XCTAssertEqual(blocks.compactMap { $0["type"] as? String }, ["heading_2", "bulleted_list_item", "numbered_list_item", "to_do", "code"])
        let bullet = try XCTUnwrap(blocks[1]["bulleted_list_item"] as? [String: Any])
        let rich = try XCTUnwrap(bullet["rich_text"] as? [[String: Any]])
        XCTAssertTrue(rich.contains { ($0["annotations"] as? [String: Any])?["bold"] as? Bool == true })
        let plain = rich.compactMap { ($0["text"] as? [String: Any])?["content"] as? String }.joined()
        XCTAssertEqual(plain, "Revenue is not cash.")
        var meeting = Meeting()
        meeting.summary = (0..<250).map { "- Specific point \($0): keep its worked example." }.joined(separator: "\n")
        let long = NotionClient.content(meeting, transcript: false)
        XCTAssertEqual(long.filter { $0["type"] as? String == "bulleted_list_item" }.count, 250)
        XCTAssertFalse(long.contains { $0["type"] as? String == "quote" })
    }
    func testPrivatePageParentIsWorkspaceInsteadOfSelectedPage() {
        let top = NotionClient.pageParent(kind: "workspace", id: "ignored")
        XCTAssertEqual(top["workspace"] as? Bool, true); XCTAssertNil(top["page_id"])
        XCTAssertEqual(NotionClient.pageParent(kind: "page", id: "folder")["page_id"] as? String, "folder")
    }
    func testCombiningSectionsKeepsEveryDetailAndDoesNotSummarizeAgain() {
        let sections = (0..<150).map { SummaryResult(title: "Lecture", summary: "Worked example \($0): amount \($0 * 25)", decisions: ["Review"], actions: ["Practice"]) }
        let joined = NotesLength.combine(sections)
        for section in sections { XCTAssertTrue(joined.summary.contains(section.summary)) }
        XCTAssertEqual(joined.decisions, ["Review"]); XCTAssertEqual(joined.actions, ["Practice"])
        XCTAssertFalse(NotesLength.complete.instruction.contains("450"))
    }
    func testCalendarGridAndMultidayExclusiveEndAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!; calendar.firstWeekday = 1
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let dates = CalendarLayout.gridDates(for: day, calendar: calendar)
        XCTAssertEqual(dates.count, 42); XCTAssertEqual(calendar.component(.weekday, from: dates[0]), 1)
        let next = calendar.date(byAdding: .day, value: 1, to: day)!
        let event = CalendarMeeting(id: "test", title: "All day", start: day, end: next, calendar: "Classes", color: .blue, eventURL: nil, allDay: true)
        XCTAssertTrue(CalendarLayout.contains(event, day: day, calendar: calendar))
        XCTAssertFalse(CalendarLayout.contains(event, day: next, calendar: calendar))
        XCTAssertEqual(next.timeIntervalSince(day), 25 * 3600)
    }
    @MainActor func testTranscriptOnlyFinishesWithoutAIAndPersistsLength() async throws {
        let defaults = UserDefaults.standard; let oldSync = defaults.object(forKey: "notionAutoSync")
        defaults.set(false, forKey: "notionAutoSync")
        defer { if let oldSync { defaults.set(oldSync, forKey: "notionAutoSync") } else { defaults.removeObject(forKey: "notionAutoSync") } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(root: folder); let id = try XCTUnwrap(store.create())
        store.update(id) { $0.notes = "My notes"; $0.transcript = [TranscriptLine(seconds: 0, source: "Pasted", text: "Keep this transcript.")] }
        let pipeline = MeetingPipeline(); pipeline.finishID = id
        pipeline.finish(id: id, length: .complete, transcriptOnly: true, store: store, recorder: Recorder())
        for _ in 0..<100 { if !pipeline.working { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(pipeline.finishID); XCTAssertEqual(store.meetings.first?.pipelineStatus, "ready")
        XCTAssertEqual(Store(root: folder).meetings.first?.notesLength, .complete)
        XCTAssertEqual(store.meetings.first?.transcript.first?.text, "Keep this transcript.")
        XCTAssertEqual(store.meetings.first?.notes, "My notes")
    }
}
