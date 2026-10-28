import XCTest
@testable import Minutes

private final class NotionStub: URLProtocol {
    static var reply: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let reply = Self.reply else { throw URLError(.badServerResponse) }
            let (code, data) = try reply(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class NotionClientTests: XCTestCase {
    private func client() -> NotionClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NotionStub.self]
        return NotionClient(token: "test-not-a-real-key", session: URLSession(configuration: config))
    }
    override func tearDown() { NotionStub.reply = nil; super.tearDown() }
    func testDatabaseSetupUsesDatedSchemaAndRetainsReturnedSource() async throws {
        NotionStub.reply = { request in
            XCTAssertEqual(request.url?.host, "api.notion.com"); XCTAssertEqual(request.url?.path, "/v1/databases")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-not-a-real-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Notion-Version"), "2025-09-03")
            // URLProtocol may receive the body as an input stream instead of httpBody.
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let source = try XCTUnwrap(body["initial_data_source"] as? [String: Any])
            let properties = try XCTUnwrap(source["properties"] as? [String: Any])
            XCTAssertNotNil(properties["Name"]); XCTAssertNotNil(properties["Date"])
            XCTAssertNil(body["audio"])
            return (200, Data("{\"data_sources\":[{\"id\":\"source-123\"}],\"url\":\"https://www.notion.so/test\"}".utf8))
        }
        let result = try await client().createDatabase(parent: "parent-id")
        XCTAssertEqual(result.source, "source-123")
    }
    func testRejectedNotionKeySurfacesServerMessage() async {
        NotionStub.reply = { _ in (401, Data("{\"message\":\"API token is invalid.\"}".utf8)) }
        do { _ = try await client().call("users/me"); XCTFail("Expected rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("API token is invalid")) }
    }
}
