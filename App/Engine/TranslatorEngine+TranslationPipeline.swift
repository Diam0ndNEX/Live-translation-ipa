import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    struct PresentationTiming {
        let packet: Packet?
        let firstSeen: Double
        let queuedAt: Date
        let processingAt: Date
        let processingMs: Double
        let savedRequests: Int
        let readyAt: Date
    }

    func cancelPresentation() {
        presentationTask?.cancel(); presentationTask = nil
        presentationID = UUID()
        if waitingToDisplay { waitingToDisplay = false }
    }

    func speak(_ s: String) {
        let voices = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "pt": "pt-BR", "en": "en-US", "es": "es-ES",
                      "fr": "fr-FR", "de": "de-DE", "it": "it-IT", "ja": "ja-JP", "ko": "ko-KR", "ru": "ru-RU",
                      "ar": "ar-SA", "tr": "tr-TR", "hi": "hi-IN", "id": "id-ID", "nl": "nl-NL", "pl": "pl-PL",
                      "th": "th-TH", "vi": "vi-VN", "uk": "uk-UA"]
        if speech.isSpeaking, !flag("interruptSpeech", true) { return }
        speech.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: s)
        u.voice = AVSpeechSynthesisVoice(language: voices[targetCode] ?? targetCode)
        u.rate = Float(num("speechRate", 0.5))
        speech.speak(u)
    }
}
