// ScreenLingo – App – UI model: the one session state machine (2.1.0, spec §13.2)
// View-layer only. Derived from values the engine already publishes; no engine change.
// Free of SwiftUI so Tests/UIModel can compile it on its own.
import Foundation

/// Why a session needs the person's attention. Each reason has one sentence and one action.
enum AttentionReason: String, Equatable, CaseIterable {
    case captureLost, timedOut, packMissing, windowClosed

    var message: String {
        switch self {
        case .captureLost: return "Capture stopped unexpectedly"
        case .timedOut: return "Capture didn't start"
        case .packMissing: return "Language pack missing"
        case .windowClosed: return "Floating window is closed"
        }
    }
    var action: String {
        switch self {
        case .captureLost, .timedOut: return "Start again"
        case .packMissing: return "Get pack"
        case .windowClosed: return "Show window"
        }
    }
    /// Only a failure that stops translation is red; the rest are amber.
    var stopsTranslation: Bool { self == .captureLost || self == .packMissing }
}

/// The colour rule of §13.2: accent for live, neutral for idle, amber for paused or attention,
/// red only for a failure that stops translation. Colour is never the only signal (every phase has a word and glyph).
enum PhaseTone: Equatable { case neutral, accent, caution, failure }

enum SessionPhase: Equatable {
    case idle, starting, live, paused
    case attention(AttentionReason)

    var word: String {
        switch self {
        case .idle: return "Ready"
        case .starting: return "Starting"
        case .live: return "Live"
        case .paused: return "Paused"
        case .attention(let reason): return reason.message
        }
    }
    var symbol: String {
        switch self {
        case .idle: return "circle"
        case .starting: return "circle.dotted"
        case .live: return "circle.fill"
        case .paused: return "pause.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        }
    }
    var tone: PhaseTone {
        switch self {
        case .idle: return .neutral
        case .starting, .live: return .accent
        case .paused: return .caution
        case .attention(let reason): return reason.stopsTranslation ? .failure : .caution
        }
    }
    /// True while a broadcast is running or being set up (the Translate screen shows its live layout).
    var isSession: Bool { self != .idle }

    /// One mapping from engine facts to a phase, used by every screen.
    static func derive(capture: CaptureReadiness.State, alive: Bool, paused: Bool, pipActive: Bool, packReady: Bool) -> SessionPhase {
        switch capture {
        case .lost: return .attention(.captureLost)
        case .timedOut: return .attention(.timedOut)
        case .idle, .stopped: return .idle
        case .waiting, .connected: return .starting
        case .active:
            if !packReady { return .attention(.packMissing) }
            if paused { return .paused }
            if alive && !pipActive { return .attention(.windowClosed) }
            return .live
        }
    }
}
