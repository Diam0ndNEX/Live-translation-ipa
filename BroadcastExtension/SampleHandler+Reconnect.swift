import Foundation
import Network

/// 2.5.1: the capture link to the app heals itself.
/// Before 2.5.1 a failed UDP connection stayed failed for the rest of the broadcast: every later send failed and the
/// app showed "Capture stopped" until both were restarted. Now a failed link, or 5 sends in a row that fail, opens a
/// new connection (at most one attempt every 2 seconds). Reading, confirmation and translation are unchanged.
private let reconnectState = ReconnectState()

private final class ReconnectState {
    let lock = NSLock()
    var failedSends = 0
    var lastAttempt = 0.0
    var scheduled = false
}

extension SampleHandler {
    func watchLink(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .failed = state { self.scheduleReconnect(replacing: connection) }
        }
    }

    func noteSendResult(failed: Bool, on connection: NWConnection) {
        reconnectState.lock.lock()
        reconnectState.failedSends = failed ? reconnectState.failedSends + 1 : 0
        let due = reconnectState.failedSends >= 5
        reconnectState.lock.unlock()
        if due { scheduleReconnect(replacing: connection) }
    }

    private func scheduleReconnect(replacing old: NWConnection) {
        reconnectState.lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        guard !reconnectState.scheduled else { reconnectState.lock.unlock(); return }
        reconnectState.scheduled = true
        let wait = max(0.3, 2 - (now - reconnectState.lastAttempt))
        reconnectState.lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + wait) { [weak self] in
            reconnectState.lock.lock()
            reconnectState.scheduled = false
            reconnectState.lastAttempt = ProcessInfo.processInfo.systemUptime
            reconnectState.failedSends = 0
            reconnectState.lock.unlock()
            self?.replaceLink(old)
        }
    }

    private func replaceLink(_ old: NWConnection) {
        recognitionLock.lock()
        defer { recognitionLock.unlock() }
        // The broadcast finished (conn is nil) or the link was already replaced: nothing to do.
        guard let current = conn, current === old else { return }
        let fresh = NWConnection(host: NWEndpoint.Host("127.0.0.1"),
                                 port: NWEndpoint.Port(rawValue: Loopback.port)!, using: .udp)
        watchLink(fresh)
        fresh.start(queue: .global(qos: .userInitiated))
        conn = fresh
        heartbeatLock.lock(); if heartbeatConn != nil { heartbeatConn = fresh }; heartbeatLock.unlock()
        old.stateUpdateHandler = nil
        old.cancel()
        listen()
    }
}
