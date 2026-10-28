import XCTest
import AVFoundation
import CoreMedia
@testable import Minutes

final class MinutesTests: XCTestCase {
    func testPauseDropsAudioAndMuteWritesSilenceToFileAndSpeech() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)); buffer.frameLength = 4800
        for i in 0..<4800 { buffer.floatChannelData![0][i] = 0.25 }
        let feed = SpeechFeed(); let sink = try MicrophoneSink(url: url, format: format, feed: feed)
        sink.append(buffer)
        sink.setGate(paused: false, muted: true); sink.append(buffer)
        sink.setGate(paused: true, muted: false); sink.append(buffer)
        sink.setGate(paused: false, muted: false); sink.append(buffer)
        await sink.finish()
        XCTAssertNil(sink.status.1)
        XCTAssertEqual(feed.receivedSeconds, 0.3, accuracy: 0.0001)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 14400)
        let saved = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 14400)); try file.read(into: saved)
        XCTAssertEqual(saved.floatChannelData![0][100], 0.25, accuracy: 0.0001)
        XCTAssertEqual(saved.floatChannelData![0][4900], 0, accuracy: 0.0001)
        XCTAssertEqual(saved.floatChannelData![0][9700], 0.25, accuracy: 0.0001)
        XCTAssertEqual(buffer.floatChannelData![0][100], 0.25) // Gate never mutates capture-owned input.
    }
    func testSystemSampleBufferCopiesBothChannelsWithoutMicrophone() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)); buffer.frameLength = 480
        for i in 0..<480 { buffer.floatChannelData![0][i] = 0.1; buffer.floatChannelData![1][i] = -0.2 }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription, sampleCount: 480, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let ready = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(ready, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: buffer.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(ready), noErr)
        let copy = try ComputerAudio.pcm(from: ready)
        XCTAssertEqual(copy.frameLength, 480); XCTAssertEqual(copy.format.channelCount, 2)
        XCTAssertEqual(copy.floatChannelData![0][100], 0.1, accuracy: 0.0001)
        XCTAssertEqual(copy.floatChannelData![1][100], -0.2, accuracy: 0.0001)
    }
    func testNotionIdentifiersAndRichTextPreserveContent() throws {
        let id = "01234567-89ab-cdef-0123-456789abcdef"
        XCTAssertEqual(try NotionClient.identifier("https://www.notion.so/My-page-0123456789abcdef0123456789abcdef?v=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), id)
        XCTAssertThrowsError(try NotionClient.identifier("https://www.notion.so/no-id"))
        let source = String(repeating: "🎙️ 中文 café ", count: 500)
        let rich = NotionClient.rich(source)
        let parts = rich.compactMap { ($0["text"] as? [String: String])?["content"] }
        XCTAssertEqual(parts.joined(), source); XCTAssertTrue(parts.allSatisfy { $0.count <= 1800 })
        XCTAssertEqual(RecordingTrack.source("meeting-computer.caf"), "Computer")
        XCTAssertEqual(RecordingTrack.source("meeting-computer.m4a"), "Computer")
        XCTAssertEqual(RecordingTrack.source("meeting-mic.caf"), "Microphone")
    }
    @MainActor func testCalendarClickReusesNoteAndSeparatesRecurringOccurrences() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(root: folder)
        let start = Date(timeIntervalSince1970: 1700000000)
        func event(_ date: Date) -> CalendarMeeting { CalendarMeeting(id: CalendarMeetings.key(identifier: "recurring", calendar: "college", start: date), title: "Accounting", start: date, end: date.addingTimeInterval(3600), calendar: "Classes", color: .blue, eventURL: nil) }
        let first = try XCTUnwrap(store.open(event(start)))
        store.update(first) { $0.notes = "Keep my notes" }
        XCTAssertEqual(store.open(event(start)), first); XCTAssertEqual(store.meetings.count, 1)
        XCTAssertEqual(store.meetings.first?.notes, "Keep my notes")
        XCTAssertNotEqual(store.open(event(start.addingTimeInterval(7 * 86400))), first)
        XCTAssertEqual(store.meetings.count, 2)
    }
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
