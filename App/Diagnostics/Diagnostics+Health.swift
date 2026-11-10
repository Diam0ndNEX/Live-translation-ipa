import CryptoKit
import SwiftUI
import Charts
import os
import Darwin

extension Diagnostics {
    // MARK: Maths
    nonisolated static func summarize(_ a: [Sample]) -> Summary {
        guard !a.isEmpty else { return Summary() }
        let v = a.map { $0.v }.sorted()
        func pct(_ p: Double) -> Double { v[Swift.min(v.count - 1, Int(Double(v.count - 1) * p))] }
        return Summary(n: v.count, min: v.first ?? 0, avg: v.reduce(0, +) / Double(v.count),
                       p50: pct(0.5), p95: pct(0.95), max: v.last ?? 0, last: a.last?.v ?? 0)
    }

    nonisolated static func orientationName(_ v: Int) -> String {
        let n = ["up", "up mirrored", "down", "down mirrored", "left mirrored", "right", "right mirrored", "left"]
        return (1...8).contains(v) ? "\(n[v - 1]) (\(v))" : "\(v)"
    }

    // MARK: Health + advice
    func assessment(alive: Bool, paused: Bool) -> Assessment {
        var issues: [Issue] = []
        var score = 100
        func flag(_ sev: Int, _ title: String, _ detail: String, _ fix: Fix? = nil) {
            issues.append(Issue(severity: sev, title: title, detail: detail, fix: fix))
        }
        let ocrS = Diagnostics.summarize(Array(ocr.suffix(30)))
        let latS = Diagnostics.summarize(Array(latency.suffix(30)))
        let trS = Diagnostics.summarize(Array(translate.suffix(30)))

        if !alive {
            flag(2, "Capture isn't running", "Open Translate, tap the round Start button and choose ScreenLingo Capture.", .startCapture)
            score -= 45
        } else {
            if paused { flag(0, "Translating is paused", "Tap Resume on Translate to continue."); score -= 5 }
            if ocrS.n >= 3 {
                if ocrS.avg > 500 {
                    flag(2, "Reading the screen is slow (\(Int(ocrS.avg)) ms)", "A smaller area or the Fast speed makes it quicker.", .fastSpeed); score -= 20
                } else if ocrS.avg > 300 {
                    flag(1, "Reading is a little slow (\(Int(ocrS.avg)) ms)", "Try the Fast speed or a smaller OCR area.", .fastSpeed); score -= 10
                }
            }
            if latS.n >= 3 {
                if latS.avg > 2000 {
                    flag(2, "Translations show up late (\(Int(latS.avg)) ms)", "Check measured queue and readability hold time. Immediate display keeps confirmation enabled.", .immediateDisplay); score -= 20
                } else if latS.avg > 1200 {
                    flag(1, "Slightly delayed translations (\(Int(latS.avg)) ms)", "Immediate display removes optional readability holds without changing translation quality.", .immediateDisplay); score -= 10
                }
            }
            if s.fps > 0 && s.fps < 15 {
                flag(1, "Low frame rate (\(Int(s.fps)) fps)", "The phone may be busy or warm."); score -= 8
            }
        }
        if s.minExtFreeMB < 12 {
            flag(2, "The capture extension nearly ran out of memory (\(Int(s.minExtFreeMB)) MB left)", "iOS may close it. Use the Fast speed or a smaller OCR area.", .fastSpeed); score -= 20
        } else if s.minExtFreeMB < 20 {
            flag(1, "Memory is getting tight (\(Int(s.minExtFreeMB)) MB left)", "The Fast speed uses less memory.", .fastSpeed); score -= 8
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            flag(2, "The phone is hot", "Reading slows down automatically. Let it cool down, or lower the brightness."); score -= 15
        default: break
        }
        if alive, trS.n >= 3, trS.avg > 400,
           (UserDefaults.standard.object(forKey: "translateAhead") as? Bool) == false {
            flag(1, "Translating is a big part of the delay (\(Int(trS.avg)) ms)",
                 "Translate-ahead starts translating before the text is confirmed, so the waits overlap.", .translateAhead)
            score -= 8
        }
        if s.sessionKind.contains("Hosted") {
            flag(0, "Translations use the slower engine",
                 "The faster direct engine needs iOS 26 and both language packs downloaded.", .openLanguages)
        }
        if s.translations + s.failures > 0, Double(s.failures) / Double(s.translations + s.failures) > 0.05 {
            flag(1, "Some sentences failed to translate", "Make sure the language packs are downloaded.", .openLanguages); score -= 10
        }
        if s.rotationTries >= 3 {
            flag(1, "Sentence order keeps being re-detected", "Pick a fixed frame rotation in Settings > Area and recognition.", .fixedRotation); score -= 8
        }
        if s.captureDrops >= 2 {
            flag(1, "Capture stopped \(s.captureDrops) times", "iOS closed the extension. The Fast speed is easier on memory.", .fastSpeed); score -= 8
        }
        score = Swift.max(0, Swift.min(100, score))
        let headline = !alive ? "Not running" : (score >= 85 ? "Running smoothly" : (score >= 60 ? "Working, could be better" : "Needs attention"))
        issues.sort { $0.severity > $1.severity }
        return Assessment(score: score, headline: headline, issues: issues)
    }
}
