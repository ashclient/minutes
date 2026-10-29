import XCTest
import Combine
@testable import Minutes

final class PerformanceAndDockTests: XCTestCase {
    func testDockingAtOuterEdgesAndAcrossDisplays() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let second = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        XCTAssertEqual(RecorderDockGeometry.edge(for: CGRect(x: -60, y: 200, width: 280, height: 76), screens: [screen]), .left)
        XCTAssertEqual(RecorderDockGeometry.edge(for: CGRect(x: 1400, y: 200, width: 280, height: 76), screens: [screen]), .right)
        XCTAssertNil(RecorderDockGeometry.edge(for: CGRect(x: 1300, y: 200, width: 280, height: 76), screens: [screen, second]))
        XCTAssertEqual(RecorderDockGeometry.edge(for: CGRect(x: 400, y: 870, width: 280, height: 76), screens: [screen]), .top)
        XCTAssertEqual(RecorderDockGeometry.edge(for: CGRect(x: 400, y: -50, width: 280, height: 76), screens: [screen]), .bottom)
        for edge in [RecorderDockEdge.left, .right, .top, .bottom] {
            let arrow = RecorderDockGeometry.dockFrame(edge: edge, previous: CGRect(x: -1000, y: -1000, width: 280, height: 76), visible: screen)
            XCTAssertTrue(screen.contains(arrow)); XCTAssertLessThanOrEqual(arrow.width * arrow.height, 24 * 44)
        }
        XCTAssertTrue(screen.contains(RecorderDockGeometry.restored(CGRect(x: -80, y: 950, width: 280, height: 76), visible: screen)))
    }
    @MainActor func testMeterUpdatesDoNotInvalidateDocumentRecorder() {
        let recorder = Recorder(); var documentUpdates = 0
        let token = recorder.objectWillChange.sink { documentUpdates += 1 }
        for i in 0..<1000 { recorder.meters.elapsed = Double(i); recorder.meters.microphone = Float(i % 10) / 10; recorder.meters.computer = 0.2 }
        XCTAssertEqual(documentUpdates, 0)
        withExtendedLifetime(token) {}
    }
    @MainActor func testLiveUpdatesCoalesceAndFlushLatestWithoutDroppingText() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(root: folder); let id = try XCTUnwrap(store.create()); let buffer = TranscriptUpdates()
        let stableID = UUID()
        for i in 0..<1000 { buffer.submit(id: id, file: "mic.caf", lines: [TranscriptLine(id: stableID, seconds: 0, source: "Microphone", audioFile: "mic.caf", text: "Latest words \(i)")], store: store) }
        XCTAssertTrue(store.meetings[0].transcript.isEmpty)
        buffer.flush(store: store)
        XCTAssertEqual(store.meetings[0].transcript.first?.text, "Latest words 999")
        XCTAssertEqual(store.meetings[0].transcript.first?.id, stableID)
        store.saveNow(); XCTAssertEqual(Store(root: folder).meetings[0].transcript.first?.text, "Latest words 999")
    }
    func testLongTranscriptMergePreservesBothTracksAndStableIDs() {
        let first = (0..<10000).map { TranscriptLine(seconds: Double($0 * 2), source: "Microphone", audioFile: "mic.caf", text: "Definition and worked example \($0)") }
        let second = (0..<10000).map { TranscriptLine(seconds: Double($0 * 2 + 1), source: "Computer", audioFile: "system.caf", text: "Answer \($0)") }
        let start = Date()
        var merged: [TranscriptLine] = []
        for _ in 0..<10 { merged = TranscriptMerge.replacing(first, file: "system.caf", with: second) }
        print("PERF: ten ordered merges of 20,000 segments: \(Date().timeIntervalSince(start)) seconds")
        XCTAssertEqual(merged.count, 20000); XCTAssertEqual(merged[0].id, first[0].id); XCTAssertEqual(merged[1].id, second[0].id)
        XCTAssertEqual(merged.last?.text, "Answer 9999")
        XCTAssertEqual(merged.map(\.seconds), merged.map(\.seconds).sorted())
    }
    func testBackgroundSaveFlushKeepsNewestSnapshot() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = ArchivePersistence(root: folder)
        var meeting = Meeting(); meeting.notes = "Old snapshot"
        writer.save(Archive(meetings: [meeting])) { _ in }
        meeting.notes = "Latest snapshot"; meeting.transcript = (0..<10000).map { TranscriptLine(seconds: Double($0), source: "Mic", text: "Keep every word \($0)") }
        try writer.flush(Archive(meetings: [meeting]))
        let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: folder.appendingPathComponent("meetings.json")))
        XCTAssertEqual(archive.meetings[0].notes, "Latest snapshot"); XCTAssertEqual(archive.meetings[0].transcript.count, 10000)
    }
    func testDeliveryChoiceDoesNotLeakOwnershipAcrossPages() {
        var meeting = Meeting(); meeting.notionPageID = "old"; meeting.notionBlockIDs = ["old-block"]; meeting.notionParentKind = "page"
        let page = NotionPageChoice(id: "existing", title: "Accounting", url: "https://www.notion.so/existing")
        NotionDelivery.apply(mode: .existing, page: page, to: &meeting)
        XCTAssertEqual(meeting.notionPageID, "existing"); XCTAssertEqual(meeting.notionParentKind, "existing"); XCTAssertNil(meeting.notionBlockIDs)
        NotionDelivery.apply(mode: .local, page: nil, to: &meeting)
        XCTAssertFalse(meeting.shouldSync(automatic: true)); XCTAssertEqual(meeting.notionPageID, "existing")
        NotionDelivery.apply(mode: .newPage, page: nil, to: &meeting)
        XCTAssertNil(meeting.notionPageID); XCTAssertNil(meeting.notionParentKind); XCTAssertTrue(meeting.shouldSync(automatic: false))
    }
}
