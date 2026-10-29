import Foundation

/// Transport evidence, independent of OCR, model warm-up and translation pause.
struct CaptureReadiness {
    enum State: String {
        case idle, waiting, connected, active, lost, stopped, timedOut

        var title: String {
            switch self {
            case .idle: return "Not capturing"
            case .waiting: return "Waiting for capture"
            case .connected: return "Connected · waiting for a frame"
            case .active: return "Capture active"
            case .lost: return "Capture connection lost"
            case .stopped: return "Capture stopped"
            case .timedOut: return "Capture has not started"
            }
        }
        var symbol: String {
            switch self {
            case .active: return "record.circle.fill"
            case .waiting, .connected: return "clock.fill"
            case .lost, .timedOut: return "exclamationmark.triangle.fill"
            case .idle, .stopped: return "record.circle"
            }
        }
    }

    private(set) var state = State.idle
    private var requestedAt: TimeInterval?
    private var lastPacketAt: TimeInterval?
    private var sessionID: String?
    private var frameReceived = false

    mutating func requested(at now: TimeInterval) {
        guard ![State.active, .connected].contains(state) else { return }
        requestedAt = now
        lastPacketAt = nil
        frameReceived = false
        state = .waiting
    }

    mutating func receive(frames: Int, session: String?, stopped: Bool, at now: TimeInterval) {
        if stopped {
            if let sessionID, let session, sessionID != session { return }
            state = .stopped
            lastPacketAt = nil; requestedAt = nil; frameReceived = false
            return
        }
        if session != sessionID || lastPacketAt == nil || state == .lost {
            frameReceived = false
        }
        sessionID = session
        lastPacketAt = now
        requestedAt = nil
        frameReceived = frameReceived || frames > 0
        state = frameReceived ? .active : .connected
    }

    mutating func tick(at now: TimeInterval) {
        if let lastPacketAt, now - lastPacketAt >= 5 {
            state = .lost
            frameReceived = false
        } else if let requestedAt, now - requestedAt >= 30 {
            state = .timedOut
            self.requestedAt = nil
        }
    }
}
