import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    // MARK: Settings readers
    var ud: UserDefaults { .standard }
    func flag(_ k: String, _ d: Bool) -> Bool { (ud.object(forKey: k) as? Bool) ?? d }
    func num(_ k: String, _ d: Double) -> Double { (ud.object(forKey: k) as? Double) ?? d }
    func int(_ k: String, _ d: Int) -> Int { (ud.object(forKey: k) as? Int) ?? d }
    func list(_ k: String, lower: Bool) -> [String] {
        (ud.string(forKey: k) ?? "")
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { lower ? $0.trimmingCharacters(in: .whitespaces).lowercased() : $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    func pairs(_ k: String) -> [(String, String)] {
        (ud.string(forKey: k) ?? "").split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let from = parts[0].trimmingCharacters(in: .whitespaces)
            let to = parts[1].trimmingCharacters(in: .whitespaces)
            return from.isEmpty ? nil : (from, to)
        }
    }
    var area: OCRArea { OCRArea(rawValue: ud.string(forKey: "area") ?? "") ?? .smart }
    var windowSize: WindowSize { WindowSize(rawValue: ud.string(forKey: "winSize") ?? "") ?? .normal }
    var speed: SpeedPreset { SpeedPreset(rawValue: ud.string(forKey: "speed") ?? "") ?? .balanced }
    var frameRotMode: String { ud.string(forKey: "frameRot") ?? "auto" }
    var showOriginal: Bool { flag("showOriginal", false) }
    var pipStyle: PiPStyle {
        var st = PiPStyle.make(theme: PiPTheme(rawValue: ud.string(forKey: "theme") ?? "") ?? .dark,
                               size: PiPTextSize(rawValue: ud.string(forKey: "textSize") ?? "") ?? .auto,
                               font: PiPFont(rawValue: ud.string(forKey: "pipFont") ?? "") ?? .standard)
        st.highlightNames = flag("highlightNames", true)
        return st
    }

    func captureRequested() {
        captureReadiness.requested(at: ProcessInfo.processInfo.systemUptime)
        publishCaptureStatus()
    }

    func publishCaptureStatus() {
        if captureStatus != captureReadiness.state { captureStatus = captureReadiness.state }
    }
}
