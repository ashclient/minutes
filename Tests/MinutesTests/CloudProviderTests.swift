import XCTest
@testable import Minutes

private final class CloudMockState: @unchecked Sendable {
    let lock = NSLock()
    private var requests: [[String: Any]] = []
    func reset() { lock.lock(); defer { lock.unlock() }; requests = [] }
    func append(_ value: [String: Any]) { lock.lock(); defer { lock.unlock() }; requests.append(value) }
    func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return requests }
}
private final class CloudMock: URLProtocol {
    static let state = CloudMockState()
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
            var body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            body["test_host"] = request.url!.host; body["test_auth"] = request.value(forHTTPHeaderField: "Authorization")
            Self.state.append(body)
            let plain = body["response_format"] == nil
            let text = plain ? "## Main concept\nA clear source-supported explanation, with enough meaning to understand the concept later.\n- Keep the necessary condition beside the rule." : "{\"summary\": {\"unexpected_shape\": true}}"
            let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text], "finish_reason": "stop"]]])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class CloudProviderTests: XCTestCase {
    private func session() -> URLSession { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [CloudMock.self]; return URLSession(configuration: c) }
    func testNvidiaRequestUsesItsOwnHostModelAndCredential() throws {
        let request = try AIClient.request(key: "nvidia-only-key", system: NotesLength.basePrompt, text: "Synthetic notes", provider: .nvidia)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(request.url?.host, "integrate.api.nvidia.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer nvidia-only-key")
        XCTAssertEqual(body["model"] as? String, "nvidia/nemotron-3.5-lightning-30b-a3b")
        XCTAssertEqual((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        XCTAssertNil(body["provider"]); XCTAssertNil(body["response_format"]); XCTAssertNil(body["audio"])
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Title"))
        XCTAssertNotEqual(CloudAIProvider.nvidia.service, CloudAIProvider.openRouter.service)
        XCTAssertNotEqual(CloudAIProvider.nvidia.enabledKey, CloudAIProvider.openRouter.enabledKey)
    }
    func testCloudParserRecoversMissingOptionalFieldsMarkdownAndReasoningWrapper() throws {
        let markdown = "## Topic\nA short definition with its necessary condition.\n- A useful detail."
        XCTAssertEqual(try CloudNotesParser.parse("```markdown\n" + markdown + "\n```").summary, markdown)
        XCTAssertEqual(try CloudNotesParser.parse("<think>Internal planning.</think>\n" + markdown).summary, markdown)
        let object = try JSONSerialization.data(withJSONObject: ["summary": markdown])
        let repaired = try CloudNotesParser.parse("Here are the notes:\n" + String(decoding: object, as: UTF8.self))
        XCTAssertEqual(repaired.summary, markdown); XCTAssertTrue(repaired.actions.isEmpty)
        let wrapped = try JSONSerialization.data(withJSONObject: String(decoding: object, as: UTF8.self), options: .fragmentsAllowed)
        XCTAssertEqual(try CloudNotesParser.parse(String(decoding: wrapped, as: UTF8.self)).summary, markdown)
        let alias = try JSONSerialization.data(withJSONObject: ["notes": markdown, "actions": NSNull()])
        XCTAssertEqual(try CloudNotesParser.parse(String(decoding: alias, as: UTF8.self)).summary, markdown)
    }
    func testCloudParserRejectsMalformedJsonErrorsAndUnfinishedReasoning() throws {
        for value in ["{\"summary\":\"broken", "Here are notes:\n{\"summary\":\"broken", "{\"error\":\"service unavailable\"}", "<think>Reasoning without an answer", "I cannot generate notes for this request.", ""] {
            XCTAssertThrowsError(try CloudNotesParser.parse(value), value)
        }
        let cut = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "## Topic\nThis reply was cut before it finished."], "finish_reason": "length"]]])
        XCTAssertThrowsError(try AIClient.decode(cut, status: 200, provider: .nvidia))
        XCTAssertThrowsError(try AIClient.decode(Data(), status: 401, provider: .nvidia)) { error in XCTAssertTrue(error.localizedDescription.contains("NVIDIA")) }
    }
    @MainActor func testOpenRouterRetriesMalformedSchemaAsMarkdownWithoutSwitchingProviders() async throws {
        CloudMock.state.reset()
        let result = try await AIClient(apiKey: "openrouter-only-key", session: session()).summarize("A synthetic source concept and its necessary condition.", progress: { _ in })
        XCTAssertTrue(result.summary.contains("## Main concept"))
        let requests = CloudMock.state.snapshot()
        XCTAssertEqual(requests.count, 4) // draft + recovery, source check + recovery
        XCTAssertEqual(requests.filter { $0["response_format"] == nil }.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0["test_host"] as? String == "openrouter.ai" && $0["test_auth"] as? String == "Bearer openrouter-only-key" })
        for request in requests where request["response_format"] == nil {
            let messages = try XCTUnwrap(request["messages"] as? [[String: String]])
            XCTAssertTrue(messages[0]["content"]!.contains("Return only the finished Markdown"))
            XCTAssertFalse(messages[0]["content"]!.contains("Output only valid JSON"))
        }
    }
    @MainActor func testNvidiaConnectionCheckUsesOnlySyntheticTextAndSmallOutputBudget() async throws {
        CloudMock.state.reset()
        try await AIClient(apiKey: "nvidia-test-key", session: session(), provider: .nvidia).checkConnection()
        let request = try XCTUnwrap(CloudMock.state.snapshot().first)
        XCTAssertEqual(request["max_tokens"] as? Int, 128)
        XCTAssertEqual(request["test_host"] as? String, "integrate.api.nvidia.com")
        let messages = try XCTUnwrap(request["messages"] as? [[String: String]])
        XCTAssertEqual(messages.last?["content"], "Reply with ## Connection followed by Connection is working.")
    }
    @MainActor func testAutoCloudProgressWaitsForFinalConsolidation() async throws {
        CloudMock.state.reset(); var values: [Double] = []
        _ = try await AIClient(apiKey: "test", session: session(), provider: .nvidia).summarize("A source concept and a condition.", length: .auto, fraction: { values.append($0) }, progress: { _ in })
        XCTAssertEqual(values, values.sorted()); XCTAssertTrue(values.contains(0.85)); XCTAssertEqual(values.last, 1)
    }
    @MainActor func testNvidiaDoesNotUseOpenRouterEnabledFlagOrKey() async throws {
        let defaults = UserDefaults.standard
        let names = ["notesAIProvider", "nvidiaEnabled", "openRouterEnabled"]
        let old = names.map { defaults.object(forKey: $0) }
        defer { for (i, name) in names.enumerated() { if let value = old[i] { defaults.set(value, forKey: name) } else { defaults.removeObject(forKey: name) } } }
        defaults.set("nvidia", forKey: "notesAIProvider"); defaults.set(false, forKey: "nvidiaEnabled"); defaults.set(true, forKey: "openRouterEnabled")
        XCTAssertFalse(NotesAIProvider.selected.configured)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(root: folder); let id = try XCTUnwrap(store.create())
        store.update(id) { $0.notes = "A source definition." }
        let pipeline = MeetingPipeline(); pipeline.resume(id: id, store: store, recorder: Recorder())
        for _ in 0..<100 { if !pipeline.working { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.meetings.first?.pipelineStatus, "needsKey")
        XCTAssertEqual(store.meetings.first?.notes, "A source definition.")
    }
}
