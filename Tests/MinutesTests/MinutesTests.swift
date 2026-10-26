import XCTest
@testable import Minutes

final class MinutesTests: XCTestCase {
    func testArchiveRoundTripPreservesEditsAndTasks() throws {
        var meeting = Meeting()
        meeting.title = "Budget / planning"
        meeting.notes = "Café — 中文 🎙️"
        meeting.actions = [ActionItem(text: "Send the budget", done: true)]
        meeting.transcript = [TranscriptLine(seconds: 65.7, source: "Microphone", text: "The budget is approved.")]
        meeting.audioFiles = ["recording.m4a"]
        meeting.trashed = true
        let decoded = try JSONDecoder().decode(Archive.self, from: JSONEncoder().encode(Archive(meetings: [meeting])))
        XCTAssertEqual(decoded.meetings, [meeting])
        XCTAssertEqual(decoded.meetings[0].transcript[0].timestamp, "01:05")
    }
    func testSummaryAcceptsFencedJSONAndRejectsMissingFields() throws {
        let valid = "```json\n{\"summary\":\"Reviewed costs.\",\"decisions\":[\"Approved budget\"],\"actions\":[]}\n```"
        XCTAssertEqual(try SummaryParser.parse(valid).decisions, ["Approved budget"])
        XCTAssertThrowsError(try SummaryParser.parse("{\"summary\":\"Hello\"}"))
        XCTAssertThrowsError(try SummaryParser.parse("Not a result"))
        XCTAssertThrowsError(try SummaryParser.parse("{\"summary\":\" \",\"decisions\":[],\"actions\":[]}"))
    }
    func testChunkingBoundsUnicodeAndKeepsContent() {
        let source = String(repeating: "🎙️ café 中文", count: 70)
        let chunks = AIClient.chunks(source, limit: 37)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 37 })
        XCTAssertEqual(chunks.joined(), source)
        XCTAssertEqual(AIClient.chunks(""), [])
    }
    func testMarkdownKeepsCompletedActionsAndTranscript() {
        var meeting = Meeting()
        meeting.actions = [ActionItem(text: "Review", done: true), ActionItem(text: "Send")]
        meeting.transcript = [TranscriptLine(seconds: 75, source: "Computer", text: "Send it tomorrow.")]
        XCTAssertTrue(meeting.markdown.contains("- [x] Review"))
        XCTAssertTrue(meeting.markdown.contains("- [ ] Send"))
        XCTAssertTrue(meeting.markdown.contains("[01:15] Computer: Send it tomorrow."))
    }
    func testFreeRouterAndTextOnlyRequest() throws {
        let request = try AIClient.request(key: "test-key", system: "JSON", text: "Meeting text")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "openrouter/free")
        XCTAssertEqual(request.url?.host, "openrouter.ai")
        XCTAssertNil(body["audio"])
        XCTAssertNil(body["models"])
    }
    func testNewTitleDoesNotOverwriteUserRename() {
        var meeting = Meeting(); meeting.title = "My lecture"
        meeting.apply(SummaryResult(title: "Suggested title", summary: "Notes", decisions: [], actions: []), originalTitle: "Untitled meeting")
        XCTAssertEqual(meeting.title, "My lecture")
    }
    @MainActor func testStorePersistsAndRestoresAndRejectsUnsafeAudioPath() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(root: folder)
        store.create()
        let id = try XCTUnwrap(store.selectedID)
        store.update(id) { $0.notes = "Keep me"; $0.favorite = true }
        store.saveNow()
        let reloaded = Store(root: folder)
        XCTAssertEqual(reloaded.meetings.first?.notes, "Keep me")
        XCTAssertEqual(reloaded.meetings.first?.favorite, true)
        XCTAssertNil(store.audioURL("../meetings.json"))
        XCTAssertNotNil(store.audioURL("recording.m4a"))
    }
    @MainActor func testCorruptStoreNeverOverwritesOriginal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("meetings.json")
        let broken = Data("not json".utf8)
        try broken.write(to: file)
        let store = Store(root: folder)
        XCTAssertNotNil(store.error)
        store.create(); store.saveNow()
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }
}
