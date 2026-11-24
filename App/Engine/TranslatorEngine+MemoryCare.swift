import SwiftUI

// 2.6.3 (switch memoryCare, default ON).
// Warm-up: when memory opens, the most recently used saved units of the current rules and target language are put
// in RAM, so the first sighting of a repeated sentence needs no disk lookup. They are marked as saved (not written
// again) and are the first to go when RAM is trimmed.
// Quarantine: when a shown caption has a clear defect (a lost number, a repeated word, the source returned
// unchanged) and a unit reused from memory in that caption has the same defect on its own, that saved
// translation is sent back for validation and removed from RAM, so the next sighting is translated afresh.
// At most once per unit per app run.
extension TranslatorEngine {
    func warmRAMFromMemory() async {
        guard TranslationHotPathAB.memoryCare, memoryReady, memoryTestMode == .normal, !bypassMemory,
              !flag("freshTranslationTest", false), !targetCode.isEmpty else { return }
        let capacity = max(250, min(6000, int("memoryRAMCapacity", 3000)))
        let limit = min(MemoryCare.warmupLimit, capacity / 4)
        let entries = await memoryStore.recentEntries(rules: memoryRuleToken, target: targetCode, limit: limit)
        let bank = processMemory.normal
        var added = 0
        for (key, value) in entries where bank.values[key] == nil {
            bank.values[key] = value
            bank.savedKeys.insert(key)
            bank.use[key] = 0
            added += 1
        }
        diag.ramWarmedEntries += added
        if diag.enabled { diag.s.memoryWarmed += added }
        if added > 0 { diag.log("Memory: \(added) saved units loaded into RAM") }
    }

    func quarantineDefectiveReuse(flags: [CaptionFlag], result: String) {
        guard TranslationHotPathAB.memoryCare, memoryReady,
              !MemoryCare.quarantineFlags.isDisjoint(with: flags) else { return }
        let bank = ram
        let horizon = bank.clock >= UInt64(MemoryCare.recentTouches) ? bank.clock - UInt64(MemoryCare.recentTouches) : 0
        var suspects: [(String, String)] = []
        for key in bank.savedKeys where !quarantinedKeys.contains(key) {
            guard let used = bank.use[key], used > 0, used >= horizon, let value = bank.values[key],
                  value.count >= 4, result.contains(value), let source = MemoryCare.unitSource(key),
                  !MemoryCare.defects(source: source, translation: value).isEmpty else { continue }
            suspects.append((key, value))
        }
        guard !suspects.isEmpty else { return }
        for (key, value) in suspects {
            quarantinedKeys.insert(key)
            bank.values[key] = nil; bank.use[key] = nil; bank.savedKeys.remove(key)
            bank.dropCaptions { $0.translated.contains(value) }
        }
        let store = memoryStore
        Task { [weak self] in
            var changed = 0
            for (key, _) in suspects { changed += await store.quarantine(requestedKey: key) }
            guard let self else { return }
            if self.diag.enabled { self.diag.s.memoryQuarantined += suspects.count }
            self.diag.log("Memory: \(suspects.count) reused translation(s) with a defect sent back for a fresh translation (\(changed) saved rows)")
        }
    }
}
