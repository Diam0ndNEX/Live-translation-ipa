// ScreenLingo – App – UI kit: CaptionPreview (2.1.0, spec §13.4.3)
import SwiftUI
import UIKit

/// A miniature of the real floating caption. It draws with the same `PiPRenderer.image` and `PiPStyle.make` the engine
/// uses, so what it shows is what the window shows. It reads (never writes) every key that changes the drawing, so it
/// redraws when any of them changes.
struct CaptionPreview: View {
    var translated: String = "Rem: Wait, is Subaru the son of a god? Why didn't he ever tell us?"
    var original: String = "Rem: Espera, o Subaru é filho de um deus?"
    /// Overrides for a scene thumbnail; nil means "use the saved setting".
    var themeOverride: String? = nil
    var compact: Bool = false

    @AppStorage("theme") private var theme = PiPTheme.dark.rawValue
    @AppStorage("textSize") private var textSize = PiPTextSize.auto.rawValue
    @AppStorage("pipFont") private var pipFont = PiPFont.standard.rawValue
    @AppStorage("highlightNames") private var highlightNames = true
    @AppStorage("winSize") private var winSize = WindowSize.normal.rawValue
    @AppStorage("showOriginal") private var showOriginal = false
    // Read inside PiPStyle.make from UserDefaults; observed here only so the preview redraws when they change.
    @AppStorage("pipWeight") private var weight = "bold"
    @AppStorage("pipAlignment") private var alignment = "left"
    @AppStorage("pipLineSpacing") private var lineSpacing = 0.0
    @AppStorage("pipPadding") private var padding = 24.0
    @AppStorage("pipScale") private var scale = 1.0
    @AppStorage("originalFraction") private var originalFraction = 0.27
    @AppStorage("speakerAccent") private var speakerAccent = "blue"

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: compact ? 120 : .infinity)
            .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 14, style: .continuous))
            .accessibilityLabel("Preview of the floating caption")
            .accessibilityValue(showOriginal ? "\(translated). Original shown." : translated)
            .id(redrawKey)
    }

    private var redrawKey: String {
        "\(weight)|\(alignment)|\(lineSpacing)|\(padding)|\(scale)|\(originalFraction)|\(speakerAccent)"
    }

    private var image: UIImage {
        var style = PiPStyle.make(theme: PiPTheme(rawValue: themeOverride ?? theme) ?? .dark,
                                  size: PiPTextSize(rawValue: textSize) ?? .auto,
                                  font: PiPFont(rawValue: pipFont) ?? .standard)
        style.highlightNames = highlightNames
        return PiPRenderer.image(original: original, translated: translated, showOriginal: showOriginal,
                                 size: (WindowSize(rawValue: winSize) ?? .normal).size, style: style)
    }
}
