import Foundation
import SwiftUI
import AppKit
import UpdateSupport

@MainActor final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    @Published private(set) var available: ReleaseUpdate?
    @Published private(set) var checking = false
    @Published private(set) var downloading = false
    @Published private(set) var message = "Checks GitHub releases for new versions."
    @Published private(set) var prepared: URL?
    var idle: () -> Bool = { false }
    var save: () -> Void = {}
    private let endpoint = URL(string: "https://api.github.com/repos/ashclient/minutes/releases/latest")!
    func checkIfDue() async {
        guard !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--preview") }),
              UserDefaults.standard.object(forKey: "automaticUpdateChecks") as? Bool ?? true,
              Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: "lastUpdateCheck") > 21600 else { return }
        await check()
    }
    func check() async {
        guard !checking, !downloading else { return }
        checking = true; message = "Checking GitHub…"; defer { checking = false }
        do {
            var request = URLRequest(url: endpoint); request.timeoutInterval = 30; request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept"); request.setValue("Minutes", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AppFailure("GitHub did not respond.") }
            if http.statusCode == 404 { throw AppFailure("No public release is available yet. The repository and release must be public for automatic updates.") }
            guard http.statusCode == 200 else { throw AppFailure("GitHub update check returned HTTP \(http.statusCode). Try again later.") }
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            let next = try ReleaseUpdate.parse(data, current: current)
            if next != available, let prepared { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()); self.prepared = nil }
            available = next
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            message = available.map { "Minutes \($0.version) is available." } ?? "You’re up to date (\(current))."
        } catch { message = error.localizedDescription }
    }
    func install() async {
        guard let release = available, !downloading else { return }
        guard idle() else { message = "Finish recording, processing and Notion sync before installing."; return }
        let destination = Bundle.main.bundleURL
        guard destination.pathExtension == "app", !destination.path.contains("/AppTranslocation/"), FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else { message = "Move Minutes to a writable Applications folder before updating."; return }
        downloading = true; message = "Downloading and verifying update…"; defer { downloading = false }
        do {
            if prepared == nil {
                var request = URLRequest(url: release.url); request.timeoutInterval = 180
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppFailure("The update download failed. The installed app is unchanged.") }
                prepared = try await Task.detached(priority: .utility) {
                    try release.verify(data)
                    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Minutes-update-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    do {
                        let zip = root.appendingPathComponent("update.zip"); try data.write(to: zip)
                        try UpdateFiles.validateEntries(UpdateFiles.run("/usr/bin/unzip", ["-Z1", zip.path]))
                        try UpdateFiles.run("/usr/bin/ditto", ["-x", "-k", zip.path, root.path])
                        let app = root.appendingPathComponent("Minutes.app")
                        try UpdateFiles.validateApp(app, expectedVersion: release.version)
                        return app
                    } catch { try? FileManager.default.removeItem(at: root); throw error }
                }.value
            }
            guard idle() else { message = "Update ready. Finish current work, then click Install & relaunch."; return }
            guard let app = prepared else { return }
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MinutesUpdateHelper")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw AppFailure("The update helper is missing. Reinstall Minutes from the release download.") }
            let status = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Minutes/update-result.txt")
            save()
            let process = Process(); process.executableURL = helper
            process.arguments = [String(ProcessInfo.processInfo.processIdentifier), app.path, destination.path, status.path]
            try process.run()
            NSApplication.shared.terminate(nil)
        } catch { message = error.localizedDescription }
    }
}
struct UpdateSettings: View {
    @ObservedObject private var updater = AppUpdater.shared
    @AppStorage("automaticUpdateChecks") private var automatic = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Updates").font(.headline)
            Toggle("Automatically check GitHub for updates", isOn: $automatic)
            Text(updater.message).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(updater.checking ? "Checking…" : "Check for updates") { Task { await updater.check() } }.disabled(updater.checking || updater.downloading)
                if updater.available != nil { Button(updater.downloading ? "Preparing…" : "Install & relaunch") { Task { await updater.install() } }.disabled(updater.downloading) }
            }
        }
    }
}
