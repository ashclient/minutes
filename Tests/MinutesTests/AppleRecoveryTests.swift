import XCTest
@testable import Minutes

final class AppleRecoveryTests: XCTestCase {
    @MainActor func testParseFailureFallsBackWithoutLosingTheOtherSections() async throws {
        let values = try await OrderedBatch.map(["first", "second", "third"], concurrency: 2) { text in
            try await AppleNotesRecovery.run {
                if text == "second" { throw AppFailure("Failed to parse generated content") }
                return SummaryResult(summary: text, decisions: [], actions: [])
            } fallback: {
                return SummaryResult(summary: text + " recovered", decisions: [], actions: [])
            }
        }
        XCTAssertEqual(values.map(\.summary), ["first", "second recovered", "third"])
    }
    @MainActor func testUserCancellationDoesNotStartFallback() async throws {
        var fallbackStarted = false
        do {
            _ = try await AppleNotesRecovery.run { throw CancellationError() } fallback: {
                fallbackStarted = true; return SummaryResult(summary: "unused", decisions: [], actions: [])
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertFalse(fallbackStarted)
    }
}
