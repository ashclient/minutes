import XCTest
@testable import Minutes

private final class ReviewStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        }
        do {
            let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let messages = body["messages"] as! [[String: String]]
            let reviewing = messages[0]["content"]!.contains("editorial verification pass")
            if reviewing {
                XCTAssertTrue(messages[1]["content"]!.contains("ORIGINAL SOURCE"))
                XCTAssertTrue(messages[1]["content"]!.contains("300 units at $10"))
            }
            let value = SummaryResult(title: "Inventory", summary: reviewing ? "## Inventory\n- Cost: 300 × $10 = $3,000." : "Draft with $4,500 cost", decisions: [], actions: [])
            let content = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            let responseData = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class AIReviewTests: XCTestCase {
    @MainActor func testSourceCheckedReviewReplacesDraftAndProgressFinishes() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReviewStub.self]
        let client = AIClient(apiKey: "test", session: URLSession(configuration: config))
        var values: [Double] = []
        let result = try await client.summarize("300 units at $10", fraction: { values.append($0) }, progress: { _ in })
        XCTAssertTrue(result.summary.contains("$3,000")); XCTAssertFalse(result.summary.contains("$4,500"))
        XCTAssertEqual(values.last, 1); XCTAssertEqual(values, values.sorted()); XCTAssertTrue(result.actions.isEmpty)
    }
}
