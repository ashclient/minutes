import Foundation

final class ArchivePersistence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Minutes.archive-writer", qos: .utility)
    private let root: URL
    init(root: URL) { self.root = root }
    private func write(_ archive: Archive) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(archive)
        let target = root.appendingPathComponent("meetings.json")
        if FileManager.default.fileExists(atPath: target.path) {
            let previous = try Data(contentsOf: target)
            try previous.write(to: root.appendingPathComponent("meetings.previous.json"), options: .atomic)
        }
        try data.write(to: target, options: .atomic)
    }
    func save(_ archive: Archive, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            do { try write(archive); completion(nil) }
            catch { completion(error.localizedDescription) }
        }
    }
    func flush(_ archive: Archive) throws { try queue.sync { try write(archive) } }
}
