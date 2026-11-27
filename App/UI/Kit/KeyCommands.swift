// ScreenLingo – App – UI kit: hardware keyboard shortcuts (2.7.0)
// iPad with a keyboard (and iPhone with one): hold Command to see the list. Each shortcut calls the same engine or
// router method as the on-screen button, so nothing here has its own logic.
import SwiftUI

struct KeyCommands: View {
    let engine: TranslatorEngine
    let router: AppRouter
    let feedback: FeedbackCenter

    var body: some View {
        ZStack {
            Group {
                key("Translate", "1") { router.go(.translate) }
                key("Library", "2") { router.go(.library) }
                key("Diagnostics", "3") { router.go(.diagnostics) }
                key("Settings", "4") { router.go(.settings) }
                key("Settings", ",") { router.go(.settings) }
            }
            Group {
                key("Choose languages", "l") { router.openLanguages(.target) }
                key("Swap languages", "l", [.command, .option]) {
                    guard engine.sourceCode != "auto" else { return }
                    engine.swapLanguages()
                }
                key("Focus mode", "f", [.command, .shift]) { router.go(.translate); router.present(.reader) }
                key("Session", "i", [.command, .shift]) { router.go(.translate); router.present(.status) }
                key("Open or close floating window", "p", [.command, .shift]) {
                    if engine.pipActive { engine.pip.stop() } else { engine.startPiP() }
                }
                key("Pause or resume translating", "p", [.command, .option]) {
                    guard engine.captureAlive else { return }
                    engine.paused.toggle()
                }
                key("Hold or release caption", "h", [.command, .shift]) {
                    guard !engine.translated.isEmpty else { return }
                    engine.toggleFrozenOutput()
                }
                key("Copy translation", "c", [.command, .shift]) {
                    guard !engine.translated.isEmpty else { return }
                    UIPasteboard.general.string = engine.translated
                    feedback.show("Translation copied", severity: .success)
                }
                key("Read translation aloud", "r", [.command, .shift]) {
                    guard !engine.translated.isEmpty else { return }
                    engine.speak(engine.translated)
                }
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func key(_ title: String, _ character: Character, _ modifiers: EventModifiers = .command,
                     run: @escaping () -> Void) -> some View {
        Button(title, action: run).keyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
    }
}
