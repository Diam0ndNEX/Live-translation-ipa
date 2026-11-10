import ReplayKit
import Vision
import ImageIO
import CoreImage
import Network
import os
import os.signpost

extension SampleHandler {
    /// The app sends settings back over the same link.
    func listen() {
        conn?.receiveMessage { [weak self] data, _, _, error in
            if let data, let cfg = try? JSONDecoder().decode(Config.self, from: data) { self?.config = cfg; self?.updateHeartbeat(enabled: cfg.independentHeartbeat == true) }
            guard let error else { self?.listen(); return }
            // 2.2.0: one receive error (for example the app was not listening for a moment) used to end this loop for
            // the rest of the broadcast, so pause and area changes never arrived again. A deliberate cancel still
            // ends it; anything else retries once a second until broadcastFinished clears the connection.
            if case .posix(let code) = error, code == .ECANCELED { return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in self?.listen() }
        }
    }

    func stopHeartbeat() {
        heartbeatLock.lock()
        heartbeatTimer?.cancel(); heartbeatTimer = nil
        heartbeatConn = nil
        heartbeatLock.unlock()
    }
}
