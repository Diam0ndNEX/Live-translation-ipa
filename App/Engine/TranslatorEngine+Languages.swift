import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    // MARK: Languages / downloads
    func loadLanguages() async {
        let preferred = LanguageAvailability()
        let traditional: LanguageAvailability?
        if #available(iOS 26.4, *) {
            traditional = LanguageAvailability(preferredStrategy: .lowLatency)
        } else { traditional = nil }
        // Both models can support different languages. Do not hide the installed
        // Apple Default language list when switching to explicit Low Latency.
        let defaultLanguages = await preferred.supportedLanguages
        let lowLanguages = await traditional?.supportedLanguages ?? []
        var seen = Set<String>()
        var items: [LangItem] = []
        for language in defaultLanguages + lowLanguages {
            let code = language.minimalIdentifier
            guard seen.insert(code).inserted else { continue }
            items.append(LangItem(code: code, name: Locale.current.localizedString(forIdentifier: code) ?? code))
        }
        if !items.isEmpty { languages = items.sorted { $0.name < $1.name } }
        await refreshStatus()
    }

    func refreshStatus() async {
        languageStatusTicket = UUID()
        let ticket = languageStatusTicket
        let destination = targetCode
        let currentSystem = pendingTranslationSystem
        let target = Locale.Language(identifier: destination)
        let appleDefault = LanguageAvailability()
        let lowLatency: LanguageAvailability?
        if #available(iOS 26.4, *) {
            lowLatency = LanguageAvailability(preferredStrategy: .lowLatency)
        } else { lowLatency = nil }
        var defaultResults: [String: LanguageAssetState] = [:]
        var lowResults: [String: LanguageAssetState] = [:]
        var overallResults: [String: LanguageAvailability.Status] = [:]
        languageStatusChecking = true
        // The previous mode's aggregate result is not valid for the new strategy.
        langStatus = [:]
        defaultLangStatus = [:]
        lowLatencyLangStatus = [:]
        var seen = Set<String>()
        let active = sourceCode == "auto" ? (detectedLang == "–" ? [] : [detectedLang]) : [sourceCode]
        let codes = (active + languages.map(\.code)).filter { seen.insert($0).inserted }
        for code in codes {
            guard ticket == languageStatusTicket, currentSystem == pendingTranslationSystem,
                  destination == targetCode, !Task.isCancelled else { return }
            let source = Locale.Language(identifier: code)
            let apple = Self.languageState(await appleDefault.status(from: source, to: target))
            let low: LanguageAssetState
            if let lowLatency {
                low = Self.languageState(await lowLatency.status(from: source, to: target))
            } else {
                low = .unsupported
            }
            guard ticket == languageStatusTicket, currentSystem == pendingTranslationSystem,
                  destination == targetCode, !Task.isCancelled else { return }
            defaultResults[code] = apple
            lowResults[code] = low
            let coverage = TranslationLanguageCoverage(appleDefault: apple, lowLatency: low)
            if let status = Self.platformStatus(coverage.overall(for: currentSystem)) {
                overallResults[code] = status
            }
            // The live Legacy path uses a separately keyed Apple Default lookup.
            availCache["\(source.minimalIdentifier)>\(target.minimalIdentifier)|default"] =
                (Date(), Self.platformStatus(apple) ?? .unsupported)
            if #available(iOS 26.4, *) {
                availCache["\(source.minimalIdentifier)>\(target.minimalIdentifier)|low"] =
                    (Date(), Self.platformStatus(low) ?? .unsupported)
            }
            if code == sourceCode {
                langStatus[code] = overallResults[code]
                defaultLangStatus[code] = apple
                lowLatencyLangStatus[code] = low
            }
        }
        guard ticket == languageStatusTicket, currentSystem == pendingTranslationSystem,
              destination == targetCode, !Task.isCancelled else { return }
        langStatus = overallResults
        defaultLangStatus = defaultResults
        lowLatencyLangStatus = lowResults
        languageStatusChecking = false
    }

    // MARK: Backup + bulk changes
    func snapshot() -> [String: Any] {
        var snap: [String: Any] = [:]
        for k in Self.settingKeys { if let v = ud.object(forKey: k) { snap[k] = v } }
        return snap
    }
    func exportSettings() -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: snapshot(), options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
    func importSettings(_ text: String) -> Bool {
        guard let d = text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        for k in Self.settingKeys {
            guard let v = o[k], !(v is NSNull), v is String || v is NSNumber else { continue }
            ud.set(v, forKey: k)
        }
        if let minimum = o["minDisplay"] as? NSNumber {
            ud.set(PresentationSchedule.inferredPolicy(saved: o["displayPolicy"] as? String,
                minimum: minimum.doubleValue), forKey: "displayPolicy")
        }
        reloadSettings()
        return true
    }
    /// Puts the given settings back to their defaults (used by every "Reset this page" button).
    func resetKeys(_ keys: [String]) {
        for k in keys { ud.removeObject(forKey: k) }
        reloadSettings()
        toast("Reset to defaults")
    }
    func resetAllSettings() { resetKeys(Self.settingKeys) }
    /// A picture of the current translation, for sharing.
    func snapshotImage() -> UIImage {
        PiPRenderer.image(original: original, translated: translated.isEmpty ? "Nothing translated yet" : translated,
                          showOriginal: showOriginal, size: windowSize.size, style: pipStyle)
    }
}
