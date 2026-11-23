import Foundation

/// 2.6.0: captions that the app flagged by itself (see CaptionSignals), kept on this phone so a report can show them.
/// This is the only place that keeps subtitle text for diagnostics. It is bounded (200 notes), removed after 14 days,
/// never written without a flag, and leaves the phone only inside a report the owner exports, and only while the
/// setting "Include flagged captions' text in reports" is on (default on; the report says so in its header).
@MainActor
final class FlaggedCaptionStore {
    static let shared = FlaggedCaptionStore()
    static let maximumNotes = 200
    static let keepDays = 14.0
    static let maximumCharacters = 600
    static let settingKey = "flaggedCaptionText"

    private(set) var notes: [FlaggedCaptionNote] = []
    private var loaded = false
    private var lastSavedKey = ""
    private var lastSavedAt = Date.distantPast
    private var pendingWrite: Task<Void, Never>?

    static var includeInReports: Bool {
        (UserDefaults.standard.object(forKey: settingKey) as? Bool) ?? true
    }

    private var url: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        return base.appendingPathComponent("FlaggedCaptions.json")
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([FlaggedCaptionNote].self, from: data) else { return }
        notes = decoded
        prune()
    }

    /// Removes notes older than the keep time and beyond the maximum.
    func prune(now: Date = Date()) {
        notes.removeAll { now.timeIntervalSince($0.date) > Self.keepDays * 86_400 }
        if notes.count > Self.maximumNotes { notes.removeFirst(notes.count - Self.maximumNotes) }
    }

    /// Returns true when a note was kept. The same caption is not kept twice within a few seconds.
    @discardableResult
    func add(flags: [CaptionFlag], original: String, translated: String, previous: [[String]], version: String,
             now: Date = Date()) -> Bool {
        loadIfNeeded()
        let key = CaptionSignals.key(translated)
        if key == lastSavedKey, now.timeIntervalSince(lastSavedAt) < 5 { return false }
        lastSavedKey = key
        lastSavedAt = now
        func cut(_ s: String) -> String { String(s.prefix(Self.maximumCharacters)) }
        notes.append(FlaggedCaptionNote(date: now, flags: flags.map(\.rawValue), original: cut(original),
            translated: cut(translated), previous: previous.map { $0.map(cut) }, version: version))
        prune(now: now)
        scheduleWrite()
        return true
    }

    func notes(from start: Date, to end: Date) -> [FlaggedCaptionNote] {
        loadIfNeeded()
        return notes.filter { $0.date >= start.addingTimeInterval(-5) && $0.date <= end.addingTimeInterval(5) }
    }

    func deleteAll() {
        notes.removeAll()
        scheduleWrite()
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, let url = self.url,
                  let data = try? JSONEncoder().encode(self.notes) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
    }
}
