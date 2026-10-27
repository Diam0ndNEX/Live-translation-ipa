import Foundation

/// Serializes persistence so an older background save cannot undo a later Clear action.
actor MemoryWriter {
    private var latestRevision = 0
    func save(_ snapshot: [String: String], to url: URL, revision: Int) -> Bool {
        guard revision > latestRevision else { return true }
        latestRevision = revision
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }
    func clear(_ url: URL, revision: Int) {
        guard revision > latestRevision else { return }
        latestRevision = revision
        try? FileManager.default.removeItem(at: url)
    }
}
