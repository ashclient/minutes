import XCTest
@testable import Minutes

private final class GoogleTokenCapture: @unchecked Sendable {
    let lock = NSLock()
    var value: (URL?, String) = (nil, "")
    func set(_ url: URL?, _ body: String) { lock.lock(); defer { lock.unlock() }; value = (url, body) }
    func get() -> (URL?, String) { lock.lock(); defer { lock.unlock() }; return value }
}
private final class GoogleHostedMock: URLProtocol {
    static let captured = GoogleTokenCapture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(contentsOf: buffer.prefix(n)) }
        }
        Self.captured.set(request.url, String(decoding: body, as: UTF8.self))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","expires_in":3600}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class GoogleHostedAuthTests: XCTestCase {
    func testPublicConfigRejectsUnsafeEndpointAndMixedSecret() throws {
        for raw in ["http://auth.example.com/v1/token", "https://user:pass@auth.example.com/v1/token", "https://auth.example.com/v1/token?x=y", "https://auth.example.com/other", "https://127.0.0.1/v1/token", "https://localhost/v1/token"] { XCTAssertNil(GoogleClientConfig.proxyURL(raw), raw) }
        XCTAssertNotNil(GoogleClientConfig.proxyURL("https://auth.example.com/v1/token"))
        let mixed = #"{"installed":{"client_id":"test.apps.googleusercontent.com","client_secret":"private-value","token_proxy":"https://auth.example.com/v1/token"}}"#
        XCTAssertThrowsError(try GoogleClientConfig.imported(Data(mixed.utf8)))
    }
    func testHostedCodeAndRefreshRequestsNeverTransmitAppSecret() async throws {
        let config = GoogleClientConfig(client_id: "test.apps.googleusercontent.com", token_proxy: "https://auth.example.com/v1/token")
        let setup = URLSessionConfiguration.ephemeral; setup.protocolClasses = [GoogleHostedMock.self]
        let session = URLSession(configuration: setup); defer { session.invalidateAndCancel() }
        for values in [["client_id":config.client_id,"grant_type":"authorization_code","code":"proof","code_verifier":"verifier","redirect_uri":"http://127.0.0.1:54321/","client_secret":"must-never-leave"], ["client_id":config.client_id,"grant_type":"refresh_token","refresh_token":"saved-token","client_secret":"must-never-leave"]] {
            let result = try await config.exchange(values, session: session)
            XCTAssertEqual(result["access_token"] as? String, "synthetic-access")
            let (url, body) = GoogleHostedMock.captured.get()
            XCTAssertEqual(url?.absoluteString, config.token_proxy)
            XCTAssertFalse(body.contains("client_secret")); XCTAssertFalse(body.contains("must-never-leave"))
            XCTAssertTrue(body.contains("grant_type="))
        }
    }
    func testExistingCustomClientKeepsItsTokenIdentityAndLegacyJSONDecodes() throws {
        let old = try JSONDecoder().decode(GoogleClientConfig.self, from: Data(#"{"client_id":"old.apps.googleusercontent.com","client_secret":"synthetic-private-value"}"#.utf8))
        XCTAssertNil(old.token_proxy)
        let shared = GoogleClientConfig(client_id: "shared.apps.googleusercontent.com", token_proxy:"https://auth.example.com/v1/token")
        XCTAssertEqual(GoogleClientConfig.preferred(imported: old, shared: shared)?.client_id, old.client_id)
        let same = GoogleClientConfig(client_id: old.client_id, token_proxy: shared.token_proxy)
        XCTAssertNil(GoogleClientConfig.preferred(imported: old, shared: same)?.client_secret)
        XCTAssertEqual(GoogleClientConfig.preferred(imported: nil, shared: shared)?.token_proxy, shared.token_proxy)
        let token = try JSONDecoder().decode(GoogleTokens.self, from: Data(#"{"access":"saved-access","refresh":"saved-refresh","expires":1000000}"#.utf8))
        XCTAssertEqual(token.refresh, "saved-refresh")
    }
}
