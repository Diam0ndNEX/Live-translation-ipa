import SwiftUI

// 2.6.0: automatic quality signals for every caption that was shown. Counters are numbers only. A flagged caption is
// also kept as text in FlaggedCaptionStore (bounded, removed after 14 days) so a report can show the wording.
extension TranslatorEngine {
    /// Called from show() after a caption was enqueued to the PiP.
    func noteShownSignals(_ text: String, _ result: String) {
        let flags = captionSignals.observe(original: text, translated: result, at: ProcessInfo.processInfo.systemUptime)
        if diag.enabled { diag.s.qShown += 1 }
        defer {
            shownHistory.append([text, result])
            if shownHistory.count > 3 { shownHistory.removeFirst(shownHistory.count - 3) }
        }
        guard !flags.isEmpty else { return }
        quarantineDefectiveReuse(flags: flags, result: result) // 2.6.3
        if diag.enabled {
            for flag in flags {
                switch flag {
                case .reshownSame: diag.s.qReshownSame += 1
                case .rewrittenSoon: diag.s.qRewritten += 1
                case .unchanged: diag.s.qUnchanged += 1
                case .digitsLost: diag.s.qDigitsLost += 1
                case .lengthOutlier: diag.s.qLengthOutlier += 1
                case .repeatedWord: diag.s.qRepeatedWord += 1
                }
            }
        }
        guard FlaggedCaptionStore.includeInReports, !flag("privateSession", false) else { return }
        if FlaggedCaptionStore.shared.add(flags: flags, original: text, translated: result,
                                          previous: shownHistory, version: AppVersion.full), diag.enabled {
            diag.s.qFlaggedSaved += 1
        }
    }

    func qualitySignalsReset() {
        captionSignals.forgetShown()
        shownHistory.removeAll()
        displayStability.forget() // 2.6.4: a cleared screen starts clean
        firstReadings.forget() // 2.6.5
    }
}
