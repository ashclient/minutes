import XCTest
@testable import Minutes

final class GoogleCalendarTests: XCTestCase {
    @MainActor func testRealLoopbackListenerReceivesBrowserCallbackAndCanRetry() async throws {
        // This uses the actual Network.framework listener and HTTP connection,
        // replacing only the system browser. No Google credentials reach CI.
        let signIn = GoogleSignIn()
        let config = GoogleClientConfig(client_id: "test.apps.googleusercontent.com")
        for _ in 0..<2 {
            var requestTask: Task<Void, Error>?
            let result = await AsyncDeadline.run(seconds: 8) {
                try await signIn.authorize(config, verifier: "test-verifier", state: "test-state") { url in
                    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                    let redirect = query.first { $0.name == "redirect_uri" }!.value!
                    requestTask = Task {
                        var callback = URLComponents(string: redirect)!
                        // An unrelated browser request must not end sign-in.
                        callback.queryItems = [URLQueryItem(name: "state", value: "wrong"), URLQueryItem(name: "code", value: "ignored")]
                        _ = try await URLSession.shared.data(from: callback.url!)
                        callback.queryItems = [URLQueryItem(name: "state", value: "test-state"), URLQueryItem(name: "code", value: "test-code")]
                        let (body, response) = try await URLSession.shared.data(from: callback.url!)
                        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("test-code"))
                    }
                    return true
                }
            }
            defer { signIn.cancel(); requestTask?.cancel() }
            let (code, redirect) = try XCTUnwrap(result, "Local sign-in listener did not complete").get()
            try await requestTask?.value
            XCTAssertEqual(code, "test-code")
            XCTAssertEqual(URL(string: redirect)?.host, "127.0.0.1")
            XCTAssertGreaterThan(URL(string: redirect)?.port ?? 0, 0)
        }
    }
    @MainActor func testBrowserOpenFailureEndsSignInImmediately() async throws {
        let signIn = GoogleSignIn()
        defer { signIn.cancel() }
        let result = await AsyncDeadline.run(seconds: 8) {
            try await signIn.authorize(GoogleClientConfig(client_id: "test.apps.googleusercontent.com"), verifier: "v", state: "s", openBrowser: { _ in false })
        }
        let finished = try XCTUnwrap(result)
        XCTAssertThrowsError(try finished.get()) { error in
            XCTAssertTrue(error.localizedDescription.contains("browser"))
        }
    }
    @MainActor func testDeadlineReturnsWithoutWaitingForStalledWork() async throws {
        let quick = await AsyncDeadline.run(seconds: 1) { 42 }
        XCTAssertEqual(try quick?.get(), 42)
        let start = Date()
        let late: Result<Int, Error>? = await AsyncDeadline.run(seconds: 0.02) {
            // An OS completion callback can ignore task cancellation.
            await withCheckedContinuation { c in DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { c.resume(returning: 9) } }
        }
        XCTAssertNil(late)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
    }
    func testPKCEAndAuthorizationUseReadonlyScopesAndLoopback() throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(GoogleOAuth.challenge(verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let url = GoogleOAuth.authorization(client: "test.apps.googleusercontent.com", redirect: "http://127.0.0.1:54321/", state: "nonce", verifier: verifier)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(query.first { $0.name == "redirect_uri" }?.value, "http://127.0.0.1:54321/")
        let scopes = try XCTUnwrap(query.first { $0.name == "scope" }?.value)
        XCTAssertTrue(scopes.split(separator: " ").allSatisfy { $0.hasSuffix(".readonly") })
        XCTAssertFalse(GoogleOAuth.form(["code": "a+b &é"]).isEmpty)
        XCTAssertEqual(try GoogleOAuth.random().count, 43)
    }
    func testCallbackRejectsMissingDuplicateAndWrongState() throws {
        XCTAssertEqual(try GoogleOAuth.callback("GET /?code=abc&state=nonce HTTP/1.1\r\n\r\n", state: "nonce"), "abc")
        for path in ["/?code=abc", "/?code=abc&state=wrong", "/?code=abc&state=nonce&state=nonce", "/?error=access_denied&state=nonce", "/favicon.ico?code=abc&state=nonce"] {
            XCTAssertThrowsError(try GoogleOAuth.callback("GET " + path + " HTTP/1.1\r\n\r\n", state: "nonce"))
        }
    }
    func testGoogleCredentialsRequireDesktopClientAndRefreshRetainsToken() throws {
        XCTAssertThrowsError(try GoogleClientConfig.imported(Data("{\"web\":{\"client_id\":\"web.apps.googleusercontent.com\"}}".utf8)))
        let desktop = try GoogleClientConfig.imported(Data("{\"installed\":{\"client_id\":\"desktop.apps.googleusercontent.com\",\"client_secret\":\"test\"}}".utf8))
        XCTAssertEqual(desktop.client_id, "desktop.apps.googleusercontent.com")
        let token = try GoogleOAuth.tokens(["access_token": "new", "expires_in": 3600.0], oldRefresh: "old-refresh")
        XCTAssertEqual(token.refresh, "old-refresh")
        XCTAssertThrowsError(try GoogleOAuth.tokens(["access_token": "new", "expires_in": 3600.0]))
    }
    func testRescheduledGoogleOccurrenceKeepsIdentity() throws {
        var json: [String: Any] = ["id": "recurring_20261028T193000Z", "summary": "BUS 010", "start": ["dateTime": "2026-10-28T12:30:00-07:00"], "end": ["dateTime": "2026-10-28T13:50:00-07:00"]]
        let first = try XCTUnwrap(GoogleCalendarEvent.meeting(json, calendarID: "classes@example.com", name: "Classes"))
        json["start"] = ["dateTime": "2026-10-28T13:30:00-07:00"]
        let moved = try XCTUnwrap(GoogleCalendarEvent.meeting(json, calendarID: "classes@example.com", name: "Classes"))
        XCTAssertEqual(first.id, moved.id); XCTAssertNotEqual(first.start, moved.start)
        json["status"] = "cancelled"
        XCTAssertNil(GoogleCalendarEvent.meeting(json, calendarID: "classes@example.com", name: "Classes"))
    }
    func testNotionPageNameIncludesRealDateMention() throws {
        var meeting = Meeting(); meeting.title = "INTRODUCTION TO BUSINESS BUS 010 004"; meeting.eventStart = Date(timeIntervalSince1970: 1793215800)
        let title = NotionClient.pageTitle(meeting)
        XCTAssertEqual((title.first?["text"] as? [String: String])?["content"], meeting.title)
        let mention = try XCTUnwrap(title.last?["mention"] as? [String: Any])
        XCTAssertEqual(mention["type"] as? String, "date")
        XCTAssertEqual((mention["date"] as? [String: String])?["start"], ISO8601DateFormatter().string(from: meeting.eventStart!))
    }
    @MainActor func testShutdownIsIdempotentAndUnsyncedEditsSurviveRelaunch() async throws {
        let recorder = Recorder(); await recorder.saveForQuit(); await recorder.saveForQuit()
        XCTAssertFalse(recorder.recording)
        let computer = ComputerAudio(); try await computer.stop(); try await computer.stop()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(root: folder); let id = try XCTUnwrap(store.create())
        store.update(id) { $0.notes = "Keep this when I quit"; $0.pipelineStatus = "paused"; $0.audioFiles = ["kept-mic.caf"] }
        store.saveNow()
        let reloaded = Store(root: folder)
        XCTAssertEqual(reloaded.meetings.first?.notes, "Keep this when I quit")
        XCTAssertEqual(reloaded.meetings.first?.pipelineStatus, "paused")
        XCTAssertEqual(reloaded.meetings.first?.audioFiles, ["kept-mic.caf"])
        XCTAssertEqual(reloaded.meetings.first?.notionNeedsSync, true)
    }
}
