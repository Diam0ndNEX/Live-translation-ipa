import Foundation

/// A bounded read-only route around a busy model. The owner validates its
/// caption/context before and after every suspension. Replacement invalidates
/// the lease even if a storage implementation ignores Task cancellation.
@MainActor
final class CaptionMemoryProbe {
    private var lease = UUID()
    private var task: Task<Void, Never>?

    func cancel() {
        lease = UUID()
        task?.cancel()
        task = nil
    }

    @discardableResult
    func start(keys: [String], isCurrent: @escaping @MainActor () -> Bool,
               lookup: @escaping @MainActor (String) async -> String?,
               retain: @escaping @MainActor (String, String) -> Void,
               completed: @escaping @MainActor () -> Void) -> Bool {
        cancel()
        var seen = Set<String>()
        let unique = keys.filter { seen.insert($0).inserted }
        guard !unique.isEmpty, unique.count <= 32, isCurrent() else { return false }
        let ticket = lease
        task = Task { [weak self] in
            for key in unique {
                guard let self, self.lease == ticket, !Task.isCancelled, isCurrent() else { return }
                let value = await lookup(key)
                guard self.lease == ticket, !Task.isCancelled, isCurrent() else { return }
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                retain(key, value)
            }
            guard let self, self.lease == ticket, !Task.isCancelled, isCurrent() else { return }
            self.task = nil
            completed()
        }
        return true
    }
}
