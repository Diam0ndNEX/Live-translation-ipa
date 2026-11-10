import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    /// Called when the app becomes active: opens the window once if capture is alive, the setting is on and the
    /// window was skipped at capture start.
    func openSkippedWindow() {
        let wanted = autoOpenSkipped && captureAlive && flag("autoOpenPiP", true) && !pip.isActive
        autoOpenSkipped = false
        if wanted { startPiP() }
    }

    func startPiP(then done: @escaping () -> Void = {}) {
        // 2.2.2: a failed audio session used to be swallowed. The window can still work without it, so the start goes
        // on, but the failure is recorded.
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try s.setActive(true)
        } catch {
            diag.noteRuntimeState("pip_audio_session_failed")
        }
        pip.setSize(windowSize.size)
        attemptPiP(0, done)
    }
    private func attemptPiP(_ n: Int, _ done: @escaping () -> Void) {
        if pip.isActive { done(); return }
        switch pip.start() {
        case .started, .alreadyActive:
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { done() }
            return
        case .unsupported:
            diag.noteRuntimeState("pip_start_unsupported")
            toast("The floating window is not available on this device")
            done(); return
        case .notPossible:
            break
        }
        if n >= 8 {
            // 2.2.2: say why. A layer that is not on screen can never start; otherwise iOS said no.
            diag.noteRuntimeState(pip.isHosted ? "pip_start_not_possible" : "pip_start_not_hosted")
            status = "The floating window could not open."
            toast("The floating window could not open. Stay in ScreenLingo and try again.")
            done(); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.attemptPiP(n + 1, done) }
    }
    func swapLanguages() {
        guard sourceCode != "auto" else { status = "Pick a source language to swap"; return }
        let s = sourceCode
        suppressRecent = true
        sourceCode = targetCode
        targetCode = s
        suppressRecent = false
        noteRecentPair()
    }
    func applyWindowSize() { pip.setSize(windowSize.size) }
    func applyStyle() { pip.style = pipStyle; pip.rerender(showOriginal: showOriginal); pip.configureHeartbeat() }

    /// A shareable picture of one history entry.
    func image(for h: HistoryItem) -> UIImage {
        PiPRenderer.image(original: h.original, translated: h.translated, showOriginal: true,
                          size: CGSize(width: 720, height: 420), style: pipStyle)
    }

    func resetSession() {
        sessionStarted = Date(); limitBase = sessionStarted; sessionTranslations = 0; sessionCharacters = 0
        toast("Session restarted")
    }

    func deleteHistory(ids: Set<UUID>) {
        undoHistory = history.filter { ids.contains($0.id) }
        history.removeAll { ids.contains($0.id) }
        flushHistorySave()
        toast("Deleted. Undo is available in History.")
    }

    func undoHistoryDeletion() {
        guard let saved = undoHistory else { toast("Nothing to undo"); return }
        let existing = Set(history.map(\.id))
        history += saved.filter { !existing.contains($0.id) }
        history.sort { $0.date > $1.date }
        undoHistory = nil
        flushHistorySave()
        toast("History restored")
    }

    func historyCSV(_ entries: [HistoryItem]) -> String {
        ExportFormat.csv([["date", "source", "target", "original", "translation", "starred", "note"]]
            + entries.map { [$0.date.ISO8601Format(), $0.sourceLanguage ?? "", $0.targetLanguage ?? "",
                             $0.original, $0.translated, $0.starred ? "true" : "false", $0.note ?? ""] })
    }

    func historyJSON(_ entries: [HistoryItem]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    func importHistory(_ data: Data) -> Bool {
        guard data.count < 5_000_000, let entries = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return false }
        var ids = Set(history.map(\.id))
        var merged = history
        merged += entries.filter { ids.insert($0.id).inserted }
        merged.sort { $0.date > $1.date }
        history = HistoryPolicy.trimmed(merged, capacity: historyCapacity)   // starred entries are never cut (E1)
        applyHistoryRetention()
        flushHistorySave()
        return true
    }

    func applyStorageSettings() {
        let fitted = HistoryPolicy.trimmed(history, capacity: historyCapacity)
        if fitted.count != history.count { history = fitted; flushHistorySave() }
        if ram.values.count > max(500, min(6000, int("memoryRAMCapacity", 3000))) { trimCache(); memoryDirty = true }
        saveMemory()
    }
}
