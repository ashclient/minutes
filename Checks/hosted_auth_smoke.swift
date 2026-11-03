import Foundation

@main struct HostedAuthSmoke {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3, let base = URL(string: args[1]), base.scheme == "https" else { fatalError("Provide the deployed HTTPS origin and public client ID") }
        var health = URLRequest(url: base.appendingPathComponent("health")); health.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: health)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["ready"] as? Bool == true else {
            throw NSError(domain: "MinutesHostedAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native HTTPS health request failed (status \((response as? HTTPURLResponse)?.statusCode ?? 0))."])
        }
        var request = URLRequest(url: base.appendingPathComponent("v1/token")); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = ["client_id":args[2],"grant_type":"authorization_code","code":"minutes-invalid-smoke-test-code","code_verifier":String(repeating:"x",count:64),"redirect_uri":"http://127.0.0.1:54321/"]
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn:"-._~")
        request.httpBody = Data(fields.map { $0.key + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator:"&").utf8)
        let (reply, result) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        guard (result as? HTTPURLResponse)?.statusCode == 401, json?["error"] as? String == "reconnect_required" else {
            throw NSError(domain:"MinutesHostedAuth",code:2,userInfo:[NSLocalizedDescriptionKey:"Native synthetic exchange did not reach expected provider rejection (status \((result as? HTTPURLResponse)?.statusCode ?? 0))."])
        }
        print("Native hosted-auth smoke passed: health ready; fabricated code rejected; no user tokens or meeting data used.")
    }
}
