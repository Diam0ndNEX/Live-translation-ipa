import Foundation
import Network

@main struct TransportTests {
    @MainActor static func main() async throws {
        let port: UInt16 = 49839
        let server = LoopbackServer(port: port)
        var frames = Set<Int>()
        var receivedConfig: Config?
        var ready = false
        var readyEvents = 0
        server.onPacket = { frames.insert($0.frames) }
        server.onReady = { ready = true; readyEvents += 1 }
        server.start()
        server.start() // Foreground activation must leave the healthy link alone.
        for _ in 0..<50 {
            if ready { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(ready, "The localhost listener must become ready before client startup")
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        client.start(queue: .global(qos: .userInitiated))

        @MainActor func exchange(_ connection: NWConnection, frame: Int) async throws {
            let data = Data("{\"kind\":\"ping\",\"version\":\"test\",\"frames\":\(frame),\"lines\":[]}".utf8)
            for _ in 0..<50 {
                connection.send(content: data, completion: .contentProcessed { _ in })
                try await Task.sleep(nanoseconds: 100_000_000)
                if frames.contains(frame) { return }
            }
            preconditionFailure("Local capture packet was not delivered")
        }

        try await exchange(client, frame: 1)
        server.start()
        try await exchange(client, frame: 2)
        precondition(readyEvents == 1, "Foreground activation must not recreate a healthy listener")
        client.receiveMessage { data, _, _, _ in
            guard let data, let config = try? JSONDecoder().decode(Config.self, from: data) else { return }
            Task { @MainActor in receivedConfig = config }
        }
        let config = Config(lang: "pt", y0: 0, y1: 1, maxEdge: 1400, interval: 0.22, paused: false)
        server.send(config)
        for _ in 0..<50 {
            if receivedConfig != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(receivedConfig == config, "Settings must return over the existing peer")

        // A new extension connection must receive its own settings.
        let replacement = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        replacement.start(queue: .global(qos: .userInitiated))
        try await exchange(replacement, frame: 3)
        receivedConfig = nil
        replacement.receiveMessage { data, _, _, _ in
            guard let data, let config = try? JSONDecoder().decode(Config.self, from: data) else { return }
            Task { @MainActor in receivedConfig = config }
        }
        server.send(config)
        for _ in 0..<50 {
            if receivedConfig != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(receivedConfig == config, "The restarted extension must own the settings reply")
        server.stop()
        client.cancel(); replacement.cancel()
        try await Task.sleep(nanoseconds: 200_000_000)
        ready = false
        server.start()
        for _ in 0..<50 {
            if ready { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(ready && readyEvents == 2, "Explicit stop must allow a clean listener restart")
        let restarted = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        restarted.start(queue: .global(qos: .userInitiated))
        try await exchange(restarted, frame: 4)
        server.stop(); restarted.cancel()
        print("Real localhost UDP transport, repeated activation, peer replacement and stop/restart passed")
    }
}
