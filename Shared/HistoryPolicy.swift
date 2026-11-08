// ScreenLingo – Shared – Library history rules (2.2.1, findings E1 and E15)
// Free of UIKit/SwiftUI so Tests/HistoryPolicy can compile it on its own.
import Foundation

/// What the trimming rule needs to know about one saved translation.
protocol HistoryTrimmable {
    var starred: Bool { get }
    var date: Date { get }
}

enum HistoryPolicy {
    /// Keeps every starred item and the newest `capacity` unstarred items. The order of `items` is preserved.
    ///
    /// Starred items do not count against the limit: they are the ones the person chose to keep. Before 2.2.1 the
    /// oldest entry was dropped at the limit whether it was starred or not (E1).
    static func trimmed<T: HistoryTrimmable>(_ items: [T], capacity: Int) -> [T] {
        let limit = max(0, capacity)
        var unstarred = items.indices.filter { !items[$0].starred }
        if unstarred.count <= limit { return items }
        // Newest first; equal dates keep their original position so the result is deterministic.
        unstarred.sort { a, b in
            items[a].date != items[b].date ? items[a].date > items[b].date : a < b
        }
        let dropped = Set(unstarred.dropFirst(limit))
        return items.indices.filter { !dropped.contains($0) }.map { items[$0] }
    }
}

/// Runs `action` once after calls to `schedule()` stop for `delay`. `flush()` runs it now if a call is waiting.
/// Used so the Library is written once per burst of captions instead of once per caption (E15).
@MainActor
final class DebouncedAction {
    private let delay: Duration
    private let action: () -> Void
    private var task: Task<Void, Never>?
    private(set) var isPending = false

    init(delay: Duration, action: @escaping () -> Void) {
        self.delay = delay
        self.action = action
    }

    func schedule() {
        isPending = true
        task?.cancel()
        task = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    /// Runs the action now when a call is waiting; does nothing otherwise.
    func flush() {
        task?.cancel()
        task = nil
        fire()
    }

    /// Drops a waiting call without running it.
    func cancel() {
        task?.cancel()
        task = nil
        isPending = false
    }

    private func fire() {
        guard isPending else { return }
        isPending = false
        task = nil
        action()
    }
}
