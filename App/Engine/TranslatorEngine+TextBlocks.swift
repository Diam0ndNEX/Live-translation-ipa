import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    // MARK: Text blocks
    /// Lines in reading order: top to bottom, left to right within a row.
    func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        OCRGrouping.readingOrder(lines)
    }

    func makeBlocks(_ lines: [OCRLine]) -> [[OCRLine]] {
        OCRGrouping.makeBlocks(lines, joinAdjacentText: flag("joinAdjacentText", true))
    }

    func blockHeight(_ b: [OCRLine]) -> Double {
        let h = b.map(\.h).sorted()
        return h.isEmpty ? 0 : h[h.count / 2]
    }
    func blockWeight(_ b: [OCRLine]) -> Double {
        blockHeight(b) * Double(b.reduce(0) { $0 + $1.t.count }).squareRoot()
    }

    private func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3000...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v) || (0xFF00...0xFFEF).contains(v)
    }

    /// One block's lines joined into running text ("p-" + "pq" → "p-pq").
    func blockText(_ lines: [OCRLine]) -> String {
        var out = ""
        for l in readingOrder(lines) {
            let t = l.t.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if out.isEmpty { out = t }
            else if out.hasSuffix("-") { out += t }
            else if let last = out.last, isCJK(last) { out += t }
            else { out += " " + t }
        }
        return out
    }

    func languageEvidence(_ text: String, limit: Int) -> (NLLanguage?, [NLLanguage: Double]) {
        let key = "\(limit)|\(text)"
        if let hit = languageCache[key] { return hit }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let evidence = (recognizer.dominantLanguage, recognizer.languageHypotheses(withMaximum: limit))
        if languageCache.count >= 128 { languageCache.removeAll(keepingCapacity: true) }
        languageCache[key] = evidence
        return evidence
    }

    /// Removes lines that are the floating window's own text, and learns where that window sits.
    func removeOwnOutput(_ lines: [OCRLine]) -> [OCRLine] {
        var mine: [OCRLine] = []
        var rest: [OCRLine] = []
        for l in lines {
            if TextSim.norm(l.t).count >= 3 {
                let inOutput = TextSim.containment(of: l.t, in: renderedGrams)
                let inSource = TextSim.containment(of: l.t, in: sourceGrams)
                if inOutput >= 0.85 && inOutput > inSource + 0.1 { mine.append(l); continue }
            }
            rest.append(l)
        }
        if !mine.isEmpty {
            var r = CGRect.null
            for l in mine {
                let w = l.w ?? 0.25
                r = r.union(CGRect(x: l.x - w / 2, y: l.y - l.h / 2, width: w, height: l.h))
            }
            // The original text can sit above the translation, so reach further up when it is shown
            pipRegion = r.insetBy(dx: -0.04, dy: showOriginal ? -0.18 : -0.06)
            pipRegionStamp = Date()
            if let g = pipRegion {
                if diag.enabled { diag.s.pipRegion = "x \(Int(g.minX * 100))–\(Int(g.maxX * 100))%, y \(Int(g.minY * 100))–\(Int(g.maxY * 100))%" }
            }
        }
        if let reg = pipRegion, Date().timeIntervalSince(pipRegionStamp) < 15 {
            rest.removeAll { reg.contains(CGPoint(x: $0.x, y: $0.y)) }
        }
        return rest
    }

    func dedupe(_ lines: [String]) -> [String] {
        var out: [String] = []
        for l in lines where !out.contains(where: { TextSim.similar($0, l, 0.9) }) { out.append(l) }
        return out
    }

    func performClear() {
        clearTask = nil
        guard showing, !frozen else { return }
        diag.event(.translation, "Cleared – the text ended")
        showing = false
        lastHandled = ""
        original = ""
        translated = ""
        renderedGrams = placeholderGrams
        pip.render(original: "", translated: "Listening…", showOriginal: false)
    }

    /// Only strong, long Automatic-mode evidence may discard target-language background text.
    func isTargetLanguage(_ text: String) -> Bool {
        guard sourceCode == "auto" else { return false }
        let evidence = languageEvidence(text, limit: 5).1
        return SourceLanguageRouter.shouldDropTarget(selected: sourceCode, target: targetCode,
            hypotheses: Dictionary(uniqueKeysWithValues: evidence.map { ($0.key.rawValue, $0.value) }),
            letters: text.filter(\.isLetter).count)
    }

    /// Warm-up owns a disposable session, so cancelling it cannot invalidate
    /// the retained live session. Task cancellation alone may leave model work
    /// running; explicitly ask the iOS 26 session to stop synthetic work.
    func interruptWarmupForLiveWork() {
        initialWarmupTask?.cancel()
        if initialWarmupTask != nil { initialWarmupProgress = "Warm-up yielded to live work or a changed setting" }
        initialWarmupTask = nil; initialWarmupID = UUID()
        modeService.cancelWarmup()
        guard let session = warmupSession else { return }
        warmupSuperseded = true
        if #available(iOS 26.0, *) { session.cancel() }
    }

    /// A one-slot bounded handoff; if a delayed presentation is pending, its
    /// display callback replays the newest confirmed candidate.
    func replayDeferredConfirmedIfPossible() {
        guard !busy, !waitingToDisplay, let packet = deferredConfirmedPacket else { return }
        deferredConfirmedPacket = nil
        confirmedHandoffDeadlineTask?.cancel()
        confirmedHandoffDeadlineTask = nil
        guard !paused, !manualMode, captureAlive else { return }
        handleContent(packet, receivedAt: deferredConfirmedReceivedAt, replayed: true)
    }
}
