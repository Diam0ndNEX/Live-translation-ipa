import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    // MARK: Small helpers
    /// Short message that slides in at the top of the screen.
    func toast(_ text: String) {
        toastToken += 1
        let token = toastToken
        toastText = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            if self?.toastToken == token { self?.toastText = nil }
        }
    }

    /// Light tick under the finger (can be turned off in Settings → Interface).
    func tap() { if flag("uiHaptics", true) { UISelectionFeedbackGenerator().selectionChanged() } }

    func noteRecentPair() {
        guard !suppressRecent else { return }
        let pair = "\(sourceCode)>\(targetCode)"
        var r = recentPairs.filter { $0 != pair }
        r.insert(pair, at: 0)
        recentPairs = Array(r.prefix(5))
        ud.set(recentPairs, forKey: "recentPairs")
    }

    func applyPair(_ pair: String) {
        let p = pair.split(separator: ">", maxSplits: 1).map(String.init)
        guard p.count == 2 else { return }
        suppressRecent = true
        sourceCode = p[0]
        targetCode = p[1]
        suppressRecent = false
        noteRecentPair()
        tap()
    }

    var historyCapacity: Int { max(100, min(1000, int("historyCapacity", 500))) }

    /// The stored Library as it is on disk (current key first, then the oldest key), or nil when there is none.
    private func storedHistory() -> [HistoryItem]? {
        struct Stored: Decodable {
            let id: UUID?
            let original: String
            let translated: String
            let date: Date
            let starred: Bool?
            let sourceLanguage: String?
            let targetLanguage: String?
            let note: String?
        }
        let data = ud.data(forKey: "historyData") ?? ud.data(forKey: "screenlingo.history.v1")
        guard let data, let records = try? JSONDecoder().decode([Stored].self, from: data) else { return nil }
        return records.map { HistoryItem(id: $0.id ?? UUID(), original: $0.original,
                                         translated: $0.translated, date: $0.date, starred: $0.starred ?? false,
                                         sourceLanguage: $0.sourceLanguage, targetLanguage: $0.targetLanguage, note: $0.note) }
    }

    func loadHistory() {
        guard flag("saveHistory", true), let stored = storedHistory() else { return }
        history = HistoryPolicy.trimmed(stored, capacity: historyCapacity)
        applyHistoryRetention()
    }

    /// 2.2.1 (U5): switching "Save translation history" off no longer deletes the stored Library; it only stops
    /// saving and loading. Switching it on again brings the stored Library back and merges it with this session's items.
    func historySavingChanged() {
        guard flag("saveHistory", true), let stored = storedHistory() else { return }
        var ids = Set(history.map(\.id))
        var merged = history
        merged += stored.filter { ids.insert($0.id).inserted }
        merged.sort { $0.date > $1.date }
        history = HistoryPolicy.trimmed(merged, capacity: historyCapacity)
        applyHistoryRetention()
        flushHistorySave()
    }
}
