import Foundation
import AppKit
import Network
import CryptoKit
import Security

struct GoogleClientConfig: Codable {
    var client_id: String
    var client_secret: String?
    static func imported(_ data: Data) throws -> Self {
        struct Download: Decodable { let installed: GoogleClientConfig? }
        guard let client = try JSONDecoder().decode(Download.self, from: data).installed,
              client.client_id.hasSuffix(".apps.googleusercontent.com") else { throw AppFailure("Choose Google's downloaded Desktop app OAuth JSON file.") }
        return client
    }
}
struct GoogleTokens: Codable {
    var access: String
    var refresh: String
    var expires: Date
}
enum GoogleOAuth {
    static let scopes = "https://www.googleapis.com/auth/calendar.events.readonly https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AppFailure("Could not start a secure Google sign-in.") }
        return base64(Data(bytes))
    }
    static func base64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func challenge(_ verifier: String) -> String { base64(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func authorization(client: String, redirect: String, state: String, verifier: String) -> URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = ["client_id": client, "redirect_uri": redirect, "response_type": "code", "scope": scopes, "state": state, "code_challenge": challenge(verifier), "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent select_account"].map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    static func callback(_ request: String, state: String) throws -> String {
        let parts = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
        guard parts.count == 3, parts[0] == "GET", let components = URLComponents(string: "http://127.0.0.1" + parts[1]), components.path == "/" else { throw AppFailure("Invalid Google callback.") }
        let items = components.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == state else { throw AppFailure("Google sign-in state did not match. Try connecting again.") }
        if items.contains(where: { $0.name == "error" }) { throw AppFailure("Google sign-in was declined. No calendar was connected.") }
        guard items.filter({ $0.name == "code" }).count == 1, let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw AppFailure("Google did not return a sign-in code.") }
        return code
    }
    static func form(_ values: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return Data(values.sorted(by: { $0.key < $1.key }).map { $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&").utf8)
    }
    static func tokens(_ response: [String: Any], oldRefresh: String? = nil) throws -> GoogleTokens {
        guard let access = response["access_token"] as? String,
              let refresh = response["refresh_token"] as? String ?? oldRefresh, !refresh.isEmpty,
              let lifetime = response["expires_in"] as? Double else { throw AppFailure("Google did not provide offline calendar access. Connect again and allow calendar reading.") }
        return GoogleTokens(access: access, refresh: refresh, expires: Date().addingTimeInterval(lifetime))
    }
    static func exchange(_ values: [String: String], session: URLSession = .shared) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = form(values)
        let (data, response) = try await session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw AppFailure("Google authorization failed. Reconnect your account, and check that the Calendar API is enabled for your OAuth client.") }
        return json
    }
}

// A short-lived loopback listener accepts Google's redirect. No credentials or
// calendar data are returned to the browser, and it binds only to 127.0.0.1.
@MainActor final class GoogleSignIn {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<(String, String), Error>?
    private var timeout: Task<Void, Never>?
    func cancel() { finish(.failure(CancellationError())) }
    func authorize(_ config: GoogleClientConfig, verifier: String, state: String) async throws -> (String, String) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters); self.listener = listener
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                listener.stateUpdateHandler = { [weak self] status in
                    Task { @MainActor in
                        guard let self else { return }
                        switch status {
                        case .ready:
                            guard let port = listener.port else { self.finish(.failure(AppFailure("Could not open Google sign-in."))); return }
                            let redirect = "http://127.0.0.1:\(port.rawValue)/"
                            listener.newConnectionHandler = { [weak self] connection in
                                let owner = self
                                let reader = GoogleCallbackConnection(connection: connection) { request in
                                    Task { @MainActor in
                                        guard let self = owner else { return }
                                        guard let path = request.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first,
                                              URLComponents(string: "http://127.0.0.1" + path)?.queryItems?.first(where: { $0.name == "state" })?.value == state else { return }
                                        do { self.finish(.success((try GoogleOAuth.callback(request, state: state), redirect))) }
                                        catch { self.finish(.failure(error)) }
                                    }
                                }
                                reader.start()
                            }
                            if !NSWorkspace.shared.open(GoogleOAuth.authorization(client: config.client_id, redirect: redirect, state: state, verifier: verifier)) { self.finish(.failure(AppFailure("Could not open your browser for Google sign-in."))) }
                        case .failed(let error): self.finish(.failure(error))
                        default: break
                        }
                    }
                }
                listener.start(queue: DispatchQueue(label: "Minutes.google-sign-in"))
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 180_000_000_000) } catch { return }
                    self?.finish(.failure(AppFailure("Google sign-in timed out. Click Connect Google to try again.")))
                }
            }
        }, onCancel: { Task { @MainActor in self.cancel() } })
    }
    private func finish(_ result: Result<(String, String), Error>) {
        guard let continuation else { return }; self.continuation = nil
        listener?.cancel(); listener = nil; timeout?.cancel(); timeout = nil
        continuation.resume(with: result)
    }
}
private final class GoogleCallbackConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let complete: @Sendable (String) -> Void
    private var data = Data()
    init(connection: NWConnection, complete: @escaping @Sendable (String) -> Void) { self.connection = connection; self.complete = complete }
    func start() { connection.start(queue: DispatchQueue(label: "Minutes.google-callback")); receive() }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] part, _, ended, error in
            if let part { data.append(part) }
            guard data.count <= 16384, error == nil else { connection.cancel(); return }
            if let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n") {
                let body = "Return to Minutes to finish connecting. You can close this browser tab."
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" + body
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { [connection, complete] _ in connection.cancel(); complete(text) })
            } else if ended { connection.cancel() } else { receive() }
        }
    }
}

@MainActor final class GoogleCalendarAccount {
    private let signIn = GoogleSignIn()
    private var refreshing: Task<GoogleTokens, Error>?
    private var generation = 0
    var configured: Bool { (try? CloudKey.read(service: "google.client").isEmpty == false) ?? false }
    var connected: Bool { (try? CloudKey.read(service: "google.tokens").isEmpty == false) ?? false }
    func importConfig(_ data: Data) throws {
        let value = try GoogleClientConfig.imported(data)
        if let old = try? loadConfig(), old.client_id != value.client_id { try disconnect() }
        try CloudKey.save(String(decoding: JSONEncoder().encode(value), as: UTF8.self), service: "google.client")
    }
    func cancelSignIn() { generation += 1; signIn.cancel() }
    func connect() async throws {
        let expected = generation
        let config = try loadConfig(); let verifier = try GoogleOAuth.random(); let state = try GoogleOAuth.random()
        let (code, redirect) = try await signIn.authorize(config, verifier: verifier, state: state)
        var values = ["client_id": config.client_id, "code": code, "code_verifier": verifier, "redirect_uri": redirect, "grant_type": "authorization_code"]
        values["client_secret"] = config.client_secret
        let response = try await GoogleOAuth.exchange(values)
        guard expected == generation else { throw CancellationError() }
        try save(GoogleOAuth.tokens(response))
    }
    func disconnect() throws { generation += 1; signIn.cancel(); refreshing?.cancel(); refreshing = nil; try CloudKey.save("", service: "google.tokens") }
    private func loadConfig() throws -> GoogleClientConfig {
        let raw = try CloudKey.read(service: "google.client")
        guard !raw.isEmpty else { throw AppFailure("Import a Google Desktop OAuth client in Connections first.") }
        return try JSONDecoder().decode(GoogleClientConfig.self, from: Data(raw.utf8))
    }
    private func save(_ tokens: GoogleTokens) throws { try CloudKey.save(String(decoding: JSONEncoder().encode(tokens), as: UTF8.self), service: "google.tokens") }
    private func access() async throws -> String {
        let expected = generation
        let raw = try CloudKey.read(service: "google.tokens")
        guard !raw.isEmpty else { throw AppFailure("Connect Google Calendar in Connections.") }
        let saved = try JSONDecoder().decode(GoogleTokens.self, from: Data(raw.utf8))
        if saved.expires > Date().addingTimeInterval(60) { return saved.access }
        if let refreshing { return try await refreshing.value.access }
        let config = try loadConfig()
        let task = Task { () throws -> GoogleTokens in
            var values = ["client_id": config.client_id, "refresh_token": saved.refresh, "grant_type": "refresh_token"]
            values["client_secret"] = config.client_secret
            return try GoogleOAuth.tokens(await GoogleOAuth.exchange(values), oldRefresh: saved.refresh)
        }
        refreshing = task; defer { refreshing = nil }
        let updated = try await task.value
        guard expected == generation else { throw CancellationError() }
        try save(updated); return updated.access
    }
    func list(_ path: String, query: [URLQueryItem] = []) async throws -> [[String: Any]] {
        let token = try await access(); var items: [[String: Any]] = []; var cursor: String?
        repeat {
            try Task.checkCancellation()
            var url = URLComponents(string: "https://www.googleapis.com/calendar/v3/" + path)!
            url.queryItems = query + (cursor.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            var request = URLRequest(url: url.url!); request.timeoutInterval = 30; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw AppFailure("Google Calendar could not load. Check your connection and OAuth Calendar API access, or reconnect Google.") }
            items += json["items"] as? [[String: Any]] ?? []; cursor = json["nextPageToken"] as? String
        } while cursor != nil
        return items
    }
}
