import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum CloudAIProvider: String, Sendable {
    case openRouter = "openrouter", nvidia
    var title: String { self == .nvidia ? "NVIDIA" : "OpenRouter" }
    var service: String { rawValue }
    var enabledKey: String { self == .nvidia ? "nvidiaEnabled" : "openRouterEnabled" }
    var endpoint: URL { self == .nvidia ? URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")! : URL(string: "https://openrouter.ai/api/v1/chat/completions")! }
    var model: String { self == .nvidia ? "nvidia/nemotron-3.5-lightning-30b-a3b" : "openrouter/free" }
    var keyURL: URL { self == .nvidia ? URL(string: "https://build.nvidia.com/nvidia/nemotron-3.5-lightning-30b-a3b")! : URL(string: "https://openrouter.ai/settings/keys")! }
}

struct CloudFormatFailure: LocalizedError {
    var errorDescription: String? { "The model’s reply could not be read as notes." }
}
// Accept well-formed note content even when a provider ignores JSON mode. Never
// turn a malformed JSON wrapper, reasoning trace or service error into notes.
enum CloudNotesParser {
    static func parse(_ source: String, depth: Int = 0) throws -> SummaryResult {
        guard depth < 3 else { throw CloudFormatFailure() }
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("<think>") {
            guard text.contains("</think>") else { throw CloudFormatFailure() }
            text = text.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.contains("<think>"), !text.contains("</think>") else { throw CloudFormatFailure() }
        if text.hasPrefix("```") && text.hasSuffix("```"), let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...].dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let strict = try? SummaryParser.parse(text) { return strict }
        var candidate = text
        if !text.hasPrefix("\""), let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first <= last { candidate = String(text[first...last]) }
        if let data = candidate.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
            if let string = value as? String { return try parse(string, depth: depth + 1) }
            if let object = value as? [String: Any] {
                let note = (object["summary"] as? String) ?? (object["notes"] as? String) ?? (object["markdown"] as? String)
                if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return SummaryResult(title: object["title"] as? String, summary: note, decisions: object["decisions"] as? [String] ?? [], actions: object["actions"] as? [String] ?? [])
                }
            }
            throw CloudFormatFailure()
        }
        // A wrapper with invalid JSON must go through a new Markdown generation,
        // rather than exposing braces, escaped newlines or truncated metadata.
        if text.hasPrefix("{") || text.hasPrefix("[") || text.range(of: #"(?m)^\s*\{"#, options: .regularExpression) != nil { throw CloudFormatFailure() }
        let lower = text.lowercased()
        if ["i cannot", "i can't", "i’m sorry", "i'm sorry", "error:", "<!doctype", "<html"].contains(where: { lower.hasPrefix($0) }) { throw CloudFormatFailure() }
        let lines = text.components(separatedBy: "\n")
        let structured = lines.contains { $0.hasPrefix("# ") || $0.hasPrefix("## ") || $0.hasPrefix("- ") || $0.hasPrefix("* ") }
        guard text.count >= 24, structured || text.split(whereSeparator: \.isWhitespace).count >= 10 else { throw CloudFormatFailure() }
        return SummaryResult(summary: text, decisions: [], actions: [])
    }
}

struct AIClient: Sendable {
    static let defaultModel = "openrouter/free"
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    let apiKey: String
    var session: URLSession = .shared
    var provider: CloudAIProvider = .openRouter

    static func markdownInstructions(_ text: String) -> String {
        text.replacingOccurrences(of: "Output only valid JSON: {\"title\":\"short descriptive title\",\"summary\":\"Markdown notes\",\"decisions\":[],\"actions\":[]}.", with: "Return only the Markdown study notes. No JSON wrapper or code fence.")
            .replacingOccurrences(of: "Keep explicit decisions and concrete tasks in their arrays instead of repeating them in summary. Empty arrays are valid; include owners and deadlines only if stated.", with: "Include only explicit coursework or commitments, with owners and dates only if stated.")
            .replacingOccurrences(of: "Return the same JSON schema.", with: "Return Markdown notes only.")
            + "\nReturn only the finished Markdown notes, no JSON, analysis, preamble or code fences."
    }
    static func request(key: String, system: String, text: String, provider: CloudAIProvider = .openRouter, markdown: Bool = false) throws -> URLRequest {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure("Add your \(provider.title) key to finish these notes.") }
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let plain = markdown || provider == .nvidia
        var body: [String: Any] = ["model": provider.model, "stream": false, "max_tokens": 8192,
            "messages": [["role": "system", "content": plain ? markdownInstructions(system) : system], ["role": "user", "content": text]]]
        if provider == .openRouter {
            request.setValue("Minutes", forHTTPHeaderField: "X-Title")
            if !plain { body["response_format"] = ["type": "json_object"]; body["provider"] = ["require_parameters": true] }
        } else {
            body["chat_template_kwargs"] = ["enable_thinking": false]
            body["temperature"] = 0.2
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    static func decode(_ data: Data, status: Int, provider: CloudAIProvider = .openRouter) throws -> SummaryResult {
        guard status == 200 else {
            switch status {
            case 401, 403: throw AppFailure("\(provider.title) rejected this key or request. Check the key and your account’s API access.")
            case 402: throw AppFailure("\(provider.title) blocked this request because of account credit limits. Your transcript is saved.")
            case 404, 410: throw AppFailure("The selected \(provider.title) model is unavailable or retired. Check for a Minutes update; your notes are saved.")
            case 429: throw AppFailure("\(provider.title)’s usage limit was reached. Your transcript is saved. Try again after your limit resets.")
            case 408, 502, 503, 504: throw AppFailure("\(provider.title) is busy or unavailable right now. Your transcript is saved; try again shortly.")
            case 202: throw AppFailure("\(provider.title) queued this request instead of completing it. Try again shortly; your current notes are kept.")
            default: throw AppFailure("\(provider.title) returned HTTP \(status). Your recording and transcript are saved.")
            }
        }
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]?
        }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw AppFailure("\(provider.title) returned an unreadable response. Retry; your transcript is saved.") }
        guard let choice = response.choices?.first, let content = choice.message.content, !content.isEmpty else { throw CloudFormatFailure() }
        guard choice.finish_reason != "length" else { throw AppFailure("The model’s answer was cut short. Try again; your current notes have not been replaced.") }
        if choice.finish_reason == "content_filter" { throw AppFailure("\(provider.title) could not produce notes for this request. Your current notes are kept.") }
        return try CloudNotesParser.parse(content)
    }
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0...1 {
            try Task.checkCancellation()
            let data: Data; let response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch { if Task.isCancelled { throw CancellationError() }; throw AppFailure("Could not reach \(provider.title). Check your connection, then retry. Your transcript is saved.") }
            guard let http = response as? HTTPURLResponse else { throw AppFailure("No response from \(provider.title).") }
            if attempt == 0, [429, 502, 503, 504].contains(http.statusCode) {
                let delay = min(30, max(2, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? (http.statusCode == 429 ? 5 : 2)))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)); continue
            }
            return (data, http)
        }
        throw AppFailure("\(provider.title) is unavailable. Try again shortly.")
    }
    private func generate(system: String, text: String) async throws -> SummaryResult {
        for formatAttempt in 0...1 {
            let request = try Self.request(key: apiKey, system: system, text: text, provider: provider, markdown: formatAttempt > 0)
            let (data, response) = try await send(request)
            do { return try Self.decode(data, status: response.statusCode, provider: provider) }
            catch is CloudFormatFailure {
                try Task.checkCancellation()
                if formatAttempt == 1 { throw AppFailure("\(provider.title) did not return usable notes after a formatting retry. Your previous notes and transcript are kept.") }
            }
        }
        throw CloudFormatFailure()
    }
    func checkConnection() async throws {
        var request = try Self.request(key: apiKey, system: "Write a two-line connection test. No private data is supplied.", text: "Reply with ## Connection followed by Connection is working.", provider: provider, markdown: true)
        request.timeoutInterval = 30
        var body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        body["max_tokens"] = 128; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await send(request)
        _ = try Self.decode(data, status: response.statusCode, provider: provider)
    }
    static func chunks(_ text: String, limit: Int = 10000) -> [String] {
        guard !text.isEmpty, limit > 0 else { return [] }
        var chunks: [String] = []; var rest = text[...]
        while rest.count > limit {
            let end = rest.index(rest.startIndex, offsetBy: limit)
            // Prefer a paragraph boundary; keep every character, including whitespace.
            let candidate = rest[..<end]
            let boundary = candidate.lastIndex(of: "\n").map { rest.index(after: $0) } ?? end
            let split = boundary == rest.startIndex ? end : boundary
            chunks.append(String(rest[..<split])); rest = rest[split...]
        }
        if !rest.isEmpty { chunks.append(String(rest)) }
        return chunks
    }
    func summarize(_ source: String, length: NotesLength = .complete, format: StudyFormat = .outline, fraction: @escaping @MainActor (Double) -> Void = { _ in }, progress: @escaping @MainActor (String) -> Void) async throws -> SummaryResult {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure("No speech was found. You can listen to the saved recording.") }
        let system = NotesLength.basePrompt + "\n" + length.instruction + "\n" + format.instruction
        // Each worker drafts then verifies its own section; a slow draft no longer
        // blocks reviews of every other section. Bound total network requests to four.
        let parts = Self.chunks(source, limit: provider == .nvidia ? 180000 : 18000)
        await progress("Writing and checking your notes…")
        let reviewed = try await OrderedBatch.map(Array(parts.enumerated()), concurrency: provider == .nvidia ? 2 : 4, progress: { value in fraction(value * (length == .complete ? 1 : 0.85)) }) { item in
            let section = try await generate(system: system, text: "<source section=\"\(item.offset + 1)\" total=\"\(parts.count)\">\n\(item.element)\n</source>")
            let previous = item.offset > 0 ? String(parts[item.offset - 1].suffix(2000)) : ""
            let draft = try JSONEncoder().encode(section)
            return try await generate(system: system + "\n" + NotesLength.reviewPrompt,
                text: "PREVIOUS SECTION (context only, do not repeat):\n" + previous + "\nORIGINAL SOURCE FOR THIS SECTION:\n" + item.element + "\nDRAFT TO CHECK:\n" + String(decoding: draft, as: UTF8.self))
        }
        let combined = NotesLength.combine(reviewed)
        guard length != .complete else { return combined }
        let final = try await generate(system: system + "\nConsolidate these extracts for the ENTIRE lecture. The selected length instruction takes priority over the detail retained in the extracts. Apply its whole-document requirements; Auto should be concise and selective. Merge synonymous topics and remove duplication across sections. No invented assignments or examples.", text: combined.summary)
        await fraction(1)
        return SummaryResult(title: combined.title, summary: StudyBudget.limit(final.summary, words: StudyBudget.maximum(length)), decisions: final.decisions, actions: final.actions)
    }
}
