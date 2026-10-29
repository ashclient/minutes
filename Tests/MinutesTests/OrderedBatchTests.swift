import XCTest
@testable import Minutes

private actor BatchTracker {
    var active = 0
    var peak = 0
    func enter() { active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
}
final class OrderedBatchTests: XCTestCase {
    @MainActor func testParallelWorkIsBoundedAndSourceOrderIsPreserved() async throws {
        let tracker = BatchTracker(); var progress: [Double] = []
        let result = try await OrderedBatch.map(Array(0..<18), concurrency: 3, progress: { progress.append($0) }) { value in
            await tracker.enter()
            do {
                try await Task.sleep(nanoseconds: UInt64(3 - value % 3) * 10_000_000)
                await tracker.leave(); return "Source \(value)"
            } catch { await tracker.leave(); throw error }
        }
        let peak = await tracker.peak, active = await tracker.active
        XCTAssertEqual(peak, 3); XCTAssertEqual(active, 0)
        XCTAssertEqual(result, (0..<18).map { "Source \($0)" })
        XCTAssertEqual(progress.first, 0); XCTAssertEqual(progress.last, 1)
        XCTAssertEqual(progress.count, 19); XCTAssertEqual(progress, progress.sorted())
    }
    @MainActor func testFailedBatchCancelsRemainingWorkPromptly() async {
        enum Expected: Error { case failure }
        let start = Date()
        do {
            let _: [Int] = try await OrderedBatch.map(Array(0..<10), concurrency: 3) { value in
                if value == 0 { throw Expected.failure }
                try await Task.sleep(nanoseconds: 2_000_000_000); return value
            }
            XCTFail("Expected failure")
        } catch { XCTAssertLessThan(Date().timeIntervalSince(start), 1) }
    }
    @MainActor func testLargeUnicodeInputKeepsEveryCharacterAndEmptyWorkCompletes() async throws {
        let source = String(repeating: "Definition: revenue ≠ cash. Worked example 👩🏽‍💻.\n", count: 5000)
        let parts = AIClient.chunks(source, limit: 12000)
        XCTAssertEqual(parts.joined(), source); XCTAssertTrue(parts.allSatisfy { $0.count <= 12000 })
        var fraction = 0.0
        let result: [Int] = try await OrderedBatch.map([], concurrency: 3, progress: { fraction = $0 }) { (value: Int) in value }
        XCTAssertTrue(result.isEmpty); XCTAssertEqual(fraction, 1)
    }
}
