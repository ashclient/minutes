import Foundation
import CryptoKit

public struct UpdateFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct ReleaseUpdate: Sendable, Equatable {
    public let version: String
    public let url: URL
    public let digest: String
    public let size: Int
    public init(version: String, url: URL, digest: String, size: Int) { self.version = version; self.url = url; self.digest = digest; self.size = size }
    public static func newer(_ lhs: String, than rhs: String) -> Bool {
        func components(_ value: String) -> [Int]? {
            let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard (2...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
            let numbers = parts.compactMap { Int($0) }; return numbers.count == parts.count ? numbers : nil
        }
        guard var a = components(lhs), var b = components(rhs) else { return false }
        let count = max(a.count, b.count); a += Array(repeating: 0, count: count - a.count); b += Array(repeating: 0, count: count - b.count)
        return a.lexicographicallyPrecedes(b) == false && a != b
    }
    public static func parse(_ data: Data, current: String) throws -> ReleaseUpdate? {
        struct Asset: Decodable { let name: String; let browser_download_url: String; let digest: String?; let size: Int }
        struct Release: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool; let assets: [Asset] }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease, newer(release.tag_name, than: current) else { return nil }
        guard let asset = release.assets.first(where: { $0.name == "Minutes-App.zip" }), let url = URL(string: asset.browser_download_url),
              url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil, url.query == nil,
              url.path.hasPrefix("/ashclient/minutes/releases/download/"), url.lastPathComponent == "Minutes-App.zip",
              let digest = asset.digest, digest.hasPrefix("sha256:"), digest.dropFirst(7).count == 64,
              digest.dropFirst(7).allSatisfy({ "0123456789abcdef".contains($0) }), (1...100_000_000).contains(asset.size) else {
            throw UpdateFailure("The GitHub release is missing a verified Minutes app asset.")
        }
        return ReleaseUpdate(version: release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name, url: url, digest: String(digest.dropFirst(7)), size: asset.size)
    }
    public func verify(_ data: Data) throws {
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == size, actual == digest else { throw UpdateFailure("The update checksum did not match GitHub. The installed app was not changed.") }
    }
}
public enum UpdateFiles {
    @discardableResult public static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure("Update verification failed (\(URL(fileURLWithPath: path).lastPathComponent)). The current app is kept.") }
        return String(decoding: output, as: UTF8.self)
    }
    public static func validateEntries(_ entries: String) throws {
        let names = entries.split(separator: "\n").map(String.init)
        guard !names.isEmpty, names.count < 20000 else { throw UpdateFailure("The update archive is invalid.") }
        for name in names {
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.hasPrefix("/"), !components.contains(".."), !name.contains("\\"),
                  name.hasPrefix("Minutes.app/") || name.hasPrefix("__MACOSX/") else { throw UpdateFailure("The update archive contains an unexpected path.") }
        }
    }
    public static func validateApp(_ url: URL, expectedVersion: String? = nil) throws {
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == "com.minutes.local",
              let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              expectedVersion == nil || version == expectedVersion,
              bundle.executableURL?.lastPathComponent == "Minutes" else { throw UpdateFailure("The downloaded bundle is not the expected Minutes version.") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--all-architectures", url.path])
    }
    // Stage on the destination volume. Keep a backup and roll back on move failure.
    public static func replace(staged: URL, destination: URL) throws -> URL {
        let fm = FileManager.default, parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".Minutes-install-" + UUID().uuidString + ".app")
        let backup = parent.appendingPathComponent(".Minutes-previous-" + UUID().uuidString + ".app")
        try fm.copyItem(at: staged, to: temporary)
        do {
            try fm.moveItem(at: destination, to: backup)
            do { try fm.moveItem(at: temporary, to: destination) }
            catch { try? fm.moveItem(at: backup, to: destination); throw error }
        } catch { try? fm.removeItem(at: temporary); throw error }
        return backup
    }
}
