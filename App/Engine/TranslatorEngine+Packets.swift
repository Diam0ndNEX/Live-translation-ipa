import SwiftUI
import CryptoKit
import Translation
import NaturalLanguage
import AVFoundation
import os
import os.signpost

extension TranslatorEngine {
    func allowsSingleCJK(_ text: String) -> Bool {
        extractingConfirmedPacket && flag("cjkSingleCharacters", true) && CJKText.isSingleCJKWord(text)
    }
}
