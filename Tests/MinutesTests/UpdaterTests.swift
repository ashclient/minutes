import XCTest
import CryptoKit
import UpdateSupport
@testable import Minutes

final class UpdaterTests: XCTestCase {
    func testReleaseVersionsRejectDowngradesAndPrereleases() throws {
        XCTAssertTrue(ReleaseUpdate.newer("v2.10.0", than: "2.9.9"))
        XCTAssertFalse(ReleaseUpdate.newer("2.4.0", than: "2.5.0"))
        XCTAssertFalse(ReleaseUpdate.newer("v2.5.0-beta", than: "2.4.0"))
        XCTAssertFalse(ReleaseUpdate.newer("2.5.0", than: "2.5"))
        let data = Data("{\"tag_name\":\"v9.0.0\",\"draft\":false,\"prerelease\":true,\"assets\":[]}".utf8)
        XCTAssertNil(try ReleaseUpdate.parse(data, current: "2.5.0"))
    }
    func testReleaseRejectsForeignURLsAndChecksumTampering() throws {
        let data = Data("trusted artifact".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        func metadata(_ url: String) throws -> Data { try JSONSerialization.data(withJSONObject: ["tag_name": "v2.6.0", "draft": false, "prerelease": false, "assets": [["name": "Minutes-App.zip", "browser_download_url": url, "size": data.count, "digest": "sha256:" + digest]]]) }
        let release = try XCTUnwrap(ReleaseUpdate.parse(metadata("https://github.com/ashclient/minutes/releases/download/v2.6.0/Minutes-App.zip"), current: "2.5.0"))
        XCTAssertNoThrow(try release.verify(data))
        XCTAssertThrowsError(try release.verify(Data("changed artifact".utf8)))
        XCTAssertThrowsError(try ReleaseUpdate.parse(metadata("https://evil.example/Minutes-App.zip"), current: "2.5.0"))
    }
    func testArchiveRejectsPathTraversalAndForeignBundles() throws {
        XCTAssertNoThrow(try UpdateFiles.validateEntries("Minutes.app/Contents/Info.plist\n__MACOSX/._Minutes.app"))
        for entry in ["../Minutes.app/file", "/Applications/Minutes.app/file", "Minutes.app/../../etc/passwd", "Other.app/Contents/file"] { XCTAssertThrowsError(try UpdateFiles.validateEntries(entry)) }
    }
    func testReplacementPreservesBackupAndUnrelatedData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staged = root.appendingPathComponent("staged.app"), installed = root.appendingPathComponent("Minutes.app"), notes = root.appendingPathComponent("notes.json")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: staged.appendingPathComponent("version"))
        try Data("old".utf8).write(to: installed.appendingPathComponent("version"))
        try Data("notes".utf8).write(to: notes)
        let backup = try UpdateFiles.replace(staged: staged, destination: installed)
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("version")), "new")
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("version")), "old")
        XCTAssertEqual(try String(contentsOf: notes), "notes")
    }
}
