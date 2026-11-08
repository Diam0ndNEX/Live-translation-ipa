// History policy tests (2.2.1, E1 and E15). Compiled standalone on the macOS runner with:
//   swiftc -parse-as-library Shared/HistoryPolicy.swift Tests/HistoryPolicy/main.swift
import Foundation

private var failures = 0
private func check(_ ok: Bool, _ what: String) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what)"); failures += 1 }
}

private struct Item: HistoryTrimmable {
    let id: Int
    var starred: Bool
    var date: Date
}

private final class Counter { var value = 0 }

@main
struct HistoryPolicyTests {
    @MainActor static func main() async {
        // E1: 600 items, newest first. The five OLDEST are starred; capacity 500.
        let now = Date()
        let items = (0..<600).map { Item(id: $0, starred: $0 >= 595, date: now.addingTimeInterval(Double(-$0) * 60)) }
        let kept = HistoryPolicy.trimmed(items, capacity: 500)
        let ids = Set(kept.map(\.id))
        check((595..<600).allSatisfy { ids.contains($0) }, "E1: all five old starred items survive the limit")
        check(kept.filter { !$0.starred }.count == 500, "E1: exactly 500 unstarred items are kept")
        check(ids.contains(0) && ids.contains(499) && !ids.contains(500) && !ids.contains(594),
              "E1: the newest unstarred are kept, the oldest unstarred are dropped")
        check(kept.map(\.id) == kept.map(\.id).sorted(), "E1: the order of the list is preserved")

        check(HistoryPolicy.trimmed(items, capacity: 0).allSatisfy { $0.starred } &&
              HistoryPolicy.trimmed(items, capacity: 0).count == 5, "E1: capacity 0 keeps only starred items")
        let few = Array(items.prefix(10))
        check(HistoryPolicy.trimmed(few, capacity: 500).map(\.id) == few.map(\.id), "E1: under the limit nothing changes")
        check(HistoryPolicy.trimmed([Item](), capacity: 5).isEmpty, "E1: an empty list stays empty")

        // E1: items sorted oldest-first by the caller still lose the oldest unstarred ones, not the newest.
        let reversed = Array(items.reversed())
        let keptReversed = Set(HistoryPolicy.trimmed(reversed, capacity: 500).map(\.id))
        check(keptReversed == ids, "E1: the result does not depend on the input order")

        // E15: ten schedule() calls inside one burst write once.
        let writes = Counter()
        let writer = DebouncedAction(delay: .milliseconds(60)) { writes.value += 1 }
        for _ in 0..<10 { writer.schedule() }
        check(writer.isPending && writes.value == 0, "E15: nothing is written before the delay")
        try? await Task.sleep(for: .milliseconds(500))
        check(writes.value == 1 && !writer.isPending, "E15: ten schedules inside one burst cause one write")

        // E15: flush writes at once and the cancelled timer does not write a second time.
        writer.schedule()
        writer.flush()
        check(writes.value == 2 && !writer.isPending, "E15: flush writes immediately")
        try? await Task.sleep(for: .milliseconds(300))
        check(writes.value == 2, "E15: a flushed schedule does not write again when its timer would have fired")

        writer.flush()
        check(writes.value == 2, "E15: flush with nothing waiting writes nothing")

        writer.schedule()
        writer.cancel()
        try? await Task.sleep(for: .milliseconds(300))
        check(writes.value == 2 && !writer.isPending, "E15: cancel drops a waiting write")

        if failures > 0 { print("\(failures) history policy test(s) failed"); exit(1) }
        print("History policy tests passed")
    }
}
