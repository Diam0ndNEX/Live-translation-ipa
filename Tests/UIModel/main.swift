// UI model tests (2.1.0, spec §13.2). Compiled standalone on the macOS runner with:
//   swiftc -parse-as-library Shared/CaptureReadiness.swift App/UI/Model/SessionPhase.swift Tests/UIModel/main.swift
import Foundation

private var failures = 0
private func check(_ ok: Bool, _ what: String) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what)"); failures += 1 }
}

@main
struct UIModelTests {
    static func main() {
        func phase(_ c: CaptureReadiness.State, alive: Bool = true, paused: Bool = false, pip: Bool = true, pack: Bool = true,
                   manual: Bool = false) -> SessionPhase {
            SessionPhase.derive(capture: c, alive: alive, paused: paused, pipActive: pip, packReady: pack, manual: manual)
        }
        check(phase(.idle) == .idle && phase(.stopped) == .idle, "idle and stopped are Ready")
        check(phase(.idle, pack: false) == .idle, "a missing pack does not alarm before a session starts")
        check(phase(.waiting) == .starting && phase(.connected) == .starting, "waiting and connected are Starting")
        check(phase(.active) == .live, "active capture is Live")
        check(phase(.active, paused: true) == .paused, "paused while active is Paused")
        check(phase(.active, pip: false) == .attention(.windowClosed), "closed floating window needs attention")
        check(phase(.active, pack: false) == .attention(.packMissing), "missing pack during a session needs attention")
        // 2.2.1 (U2): compose mode pauses capture, so the phase must say so.
        check(phase(.active, manual: true) == .typing, "typing in the compose bar during a session is Typing mode")
        check(phase(.active, paused: true, manual: true) == .typing, "typing mode wins over a plain pause")
        check(phase(.active, pip: false, manual: true) == .typing, "typing mode wins over a closed window (capture is paused anyway)")
        check(phase(.active, pack: false, manual: true) == .attention(.packMissing), "a missing pack is still reported while typing")
        check(phase(.idle, manual: true) == .idle, "typing with no session stays Ready")
        check(SessionPhase.typing.word == "Typing mode" && SessionPhase.typing.tone == .caution && SessionPhase.typing.isSession,
              "typing mode is amber, has its own word and counts as a session")
        check(phase(.lost) == .attention(.captureLost), "lost capture needs attention")
        check(phase(.timedOut) == .attention(.timedOut), "timed-out capture needs attention")

        // Colour rule: red only when translation stops; every phase has a word and a symbol.
        check(SessionPhase.attention(.captureLost).tone == .failure, "lost capture is red")
        check(SessionPhase.attention(.windowClosed).tone == .caution, "closed window is amber, not red")
        check(SessionPhase.paused.tone == .caution && SessionPhase.live.tone == .accent && SessionPhase.idle.tone == .neutral,
              "paused amber, live accent, idle neutral")
        let all: [SessionPhase] = [.idle, .starting, .live, .paused, .typing] + AttentionReason.allCases.map { .attention($0) }
        check(all.allSatisfy { !$0.word.isEmpty && !$0.symbol.isEmpty }, "every phase has a word and a glyph")
        check(AttentionReason.allCases.allSatisfy { !$0.action.isEmpty }, "every attention reason has one action")

        if failures > 0 { print("\(failures) UI model test(s) failed"); exit(1) }
        print("UI model tests passed")
    }
}
