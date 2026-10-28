import Foundation
import Network

/// Extension/app transport. All listener, peer and retry state belongs to queue.
/// Foreground activation is idempotent; explicit stop invalidates pending retries.
final class LoopbackServer {
    private var listener: NWListener?
    private var peer: NWConnection?
    private let queue = DispatchQueue(label: "loopback.server", qos: .userInitiated)
    private let port: UInt16
    private var generation: UInt64 = 0
    var onPacket: (@MainActor (Packet) -> Void)?
    var onReady: (@MainActor () -> Void)?

    init(port: UInt16 = Loopback.port) { self.port = port }
    deinit { listener?.cancel(); peer?.cancel() }

    func start() { queue.async { [weak self] in self?.startOnQueue() } }

    private func startOnQueue() {
        guard listener == nil, let localPort = NWEndpoint.Port(rawValue: port) else { return }
        generation &+= 1
        let ticket = generation
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: localPort)
        do {
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.generation == ticket, self.listener != nil else {
                    connection.cancel(); return
                }
                // A restarted extension owns the link; retire the previous peer.
                self.peer?.cancel()
                self.peer = connection
                connection.start(queue: self.queue)
                self.receive(on: connection, ticket: ticket)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.generation == ticket else { return }
                if case .ready = state {
                    Task { @MainActor [weak self] in self?.onReady?() }
                }
                if case .failed = state {
                    self.listener?.cancel(); self.listener = nil
                    self.peer?.cancel(); self.peer = nil
                    self.scheduleRetry(ticket: ticket)
                }
            }
            listener.start(queue: queue)
        } catch { scheduleRetry(ticket: ticket) }
    }

    private func scheduleRetry(ticket: UInt64) {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.generation == ticket else { return }
            self.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            self.listener?.cancel(); self.listener = nil
            self.peer?.cancel(); self.peer = nil
        }
    }

    func send(_ config: Config) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        queue.async { [weak self] in
            self?.peer?.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func receive(on connection: NWConnection, ticket: UInt64) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.generation == ticket, self.peer === connection else { return }
            if let data, data.count <= 60_000,
               let packet = try? JSONDecoder().decode(Packet.self, from: data),
               ["ping", "ocr", "clear"].contains(packet.kind), packet.lines.count <= 60 {
                Task(priority: .userInitiated) { @MainActor [weak self] in self?.onPacket?(packet) }
            }
            if error == nil { self.receive(on: connection, ticket: ticket) }
        }
    }
}
