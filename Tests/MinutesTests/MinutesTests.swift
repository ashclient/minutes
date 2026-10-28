import XCTest
import AVFoundation
@testable import Minutes

final class MinutesTests: XCTestCase {
    func testAudioSinkPreservesFramesAndFeedsSpeechWithoutMicrophone() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let feed = SpeechFeed()
        let sink = try MicrophoneSink(url: url, format: format, feed: feed)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        for i in 0..<4800 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.08) * 0.3) }
        for _ in 0..<10 { sink.append(buffer) }
        await sink.finish()
        XCTAssertNil(sink.status.1)
        XCTAssertEqual(feed.receivedSeconds, 1, accuracy: 0.001)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 48000)
        let saved = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48000))
        try file.read(into: saved)
        XCTAssertEqual(saved.frameLength, 48000)
        XCTAssertEqual(saved.floatChannelData![0][100], buffer.floatChannelData![0][100], accuracy: 0.0001)
    }
    func testAppleSpeechFormatConversionPreservesDuration() throws {
        let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let target = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let converter = SpeechPCMConverter(target: target)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4800))
        input.frameLength = 4800
        for i in 0..<4800 { input.floatChannelData![0][i] = Float(sin(Double(i) * 0.08) * 0.2) }
        var count: AVAudioFrameCount = 0
        for _ in 0..<10 {
            let converted = try converter.convert(input)
            XCTAssertEqual(converted.format, target)
            count += converted.frameLength
        }
        for tail in try converter.finish() { count += tail.frameLength }
        // Apple's resampler can pad its final filter tail by less than 1 ms.
        XCTAssertEqual(Double(count), 16000, accuracy: 16)
    }
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
