import Foundation
import Darwin
import UpdateSupport

@main struct MinutesUpdateHelper {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 5, let pid = Int32(args[1]), pid > 1 else { exit(2) }
        let staged = URL(fileURLWithPath: args[2]), destination = URL(fileURLWithPath: args[3]), result = URL(fileURLWithPath: args[4])
        func report(_ text: String) { try? text.write(to: result, atomically: true, encoding: .utf8) }
        do {
            guard destination.pathExtension == "app", destination.lastPathComponent != ".app", !destination.path.contains("/AppTranslocation/") else { throw UpdateFailure("Move Minutes to Applications before installing updates.") }
            try UpdateFiles.validateApp(staged)
            let end = Date().addingTimeInterval(60)
            while kill(pid, 0) == 0 && Date() < end { Thread.sleep(forTimeInterval: 0.2) }
            guard kill(pid, 0) != 0 else { throw UpdateFailure("Minutes did not close; the current app was kept.") }
            try UpdateFiles.validateApp(destination)
            let backup = try UpdateFiles.replace(staged: staged, destination: destination)
            report("Minutes updated successfully. Your notes and recordings were kept.")
            do { try UpdateFiles.run("/usr/bin/open", ["-n", destination.path]) }
            catch {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.moveItem(at: backup, to: destination)
                throw error
            }
            // The backup is a previous app bundle, never the user's data directory.
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        } catch {
            report("Update failed: " + error.localizedDescription)
            _ = try? UpdateFiles.run("/usr/bin/open", ["-n", destination.path])
            exit(1)
        }
    }
}
