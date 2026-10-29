import XCTest
@testable import Minutes

private final class StreamingStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        // Deliberately split an accented character across transport buffers.
        let payload = ": heartbeat\r\n\r\ndata: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"DO NOT DISPLAY\"}}]}\r\n\r\ndata: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"## Café\\n\"}}]}\r\n\r\ndata: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"- A useful definition with its necessary condition.\"},\"finish_reason\":\"stop\"}]}\r\n\r\ndata: {\"choices\":[],\"usage\":{\"total_tokens\":30}}\r\n\r\ndata: [DONE]\r\n\r\n"
        for byte in payload.utf8 { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class OKStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class CloudStreamingTests: XCTestCase {
    func testSSEMultilineDataCommentsReasoningAndDuplicateTerminalUsage() throws {
        var stream = CloudEventStream()
        for line in [": heartbeat", "", "event: message", "data: {\"choices\":", "data: [{\"delta\":{\"content\":\"## Main concept\\n- The condition matters.\"},\"finish_reason\":\"stop\"}]}", "", "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{}}", "", "data: [DONE]", ""] { try stream.line(line) }
        XCTAssertEqual(try stream.finish(provider: .openRouter).summary, "## Main concept\n- The condition matters.")
    }
    func testInterruptedTruncatedAndMidstreamErrorsNeverBecomeCompletedNotes() throws {
        for terminal in ["length", "content_filter", "error"] {
            var stream = CloudEventStream()
            try stream.line("data: {\"choices\":[{\"delta\":{\"content\":\"## Draft\\n- Partial notes with a useful definition.\"},\"finish_reason\":\"\(terminal)\"}]}")
            try stream.line(""); try stream.line("data: [DONE]"); try stream.line("")
            XCTAssertThrowsError(try stream.finish(provider: .nvidia))
        }
        var incomplete = CloudEventStream()
        try incomplete.line("data: {\"choices\":[{\"delta\":{\"content\":\"## Draft\\n- Notes are incomplete.\"}}]}"); try incomplete.line("")
        XCTAssertThrowsError(try incomplete.finish(provider: .openRouter))
        var failure = CloudEventStream()
        try failure.line("data: {\"error\":{\"message\":\"Disconnected\"}}")
        XCTAssertThrowsError(try failure.line(""))
    }
    func testReasoningAndJsonWrappersStayOutOfLivePreview() throws {
        for text in ["<thi", "<think>private reasoning", "{\"summary\":\"", "```markdown\n## Topic"] {
            var stream = CloudEventStream()
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": text]]]])
            try stream.line("data: " + String(decoding: data, as: UTF8.self)); try stream.line("")
            XCTAssertNil(stream.preview)
        }
    }
    @MainActor func testBothProvidersDeliverRealPartialUpdatesBeforeCompletion() async throws {
        for provider in [CloudAIProvider.openRouter, .nvidia] {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StreamingStub.self]
            var drafts: [String] = [], fractions: [Double] = []
            let result = try await AIClient(apiKey: "synthetic", session: URLSession(configuration: config), provider: provider).summarize("A source definition and its condition.", length: .auto, fraction: { fractions.append($0) }, progress: { _ in }, partial: { drafts.append($0) })
            XCTAssertTrue(drafts.contains("## Café")); XCTAssertTrue(drafts.contains { $0.contains("necessary condition") })
            XCTAssertFalse(drafts.contains { $0.contains("DO NOT DISPLAY") })
            XCTAssertEqual(result.summary, "## Café\n- A useful definition with its necessary condition.")
            XCTAssertTrue(fractions.contains(0.5)); XCTAssertEqual(fractions.last, 1)
        }
    }
    @MainActor func testShortSuccessfulConnectionReplyDoesNotNeedNotesFormatting() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OKStub.self]
        try await AIClient(apiKey: "synthetic", session: URLSession(configuration: config)).checkConnection()
    }
    func testExplicitModelOverrideIsUsedWithoutRandomFallback() throws {
        let request = try AIClient.request(key: "synthetic", system: "Notes", text: "Source", streaming: true, model: "provider/my-fixed-model:free")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "provider/my-fixed-model:free")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNil(body["models"]); XCTAssertNil(body["response_format"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }
}
