import Foundation

/// Manual, reproducible macOS benchmark. Not a claim about device latency.
/// Usage: memory-benchmark [3000 25000 100000 500000]
@main struct MemoryBenchmark {
    static func main() async throws {
        let sizes = CommandLine.arguments.dropFirst().compactMap(Int.init)
        let requested = sizes.isEmpty ? [3000, 25000, 100000, 500000] : sizes
        guard requested.allSatisfy({ $0 > 0 && $0 <= 500000 }),
              requested == requested.sorted() else { fatalError("Provide ascending sizes up to 500000") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screenlingo-benchmark-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranslationMemoryStore(directory: root)
        _ = try await store.prepare(legacyURLs: [])
        let rules = String(repeating: "a", count: 64)
        func key(_ i: Int) -> String { "v4|\(rules)|pt>en|0:|Bench sentence \(i)." }
        var count = 0
        var revision = 0
        print("entries,insert_ms_per_item,lookup_p50_ms,lookup_p95_ms,lookup_misses,database_bytes")
        for target in requested {
            let writeStart = ProcessInfo.processInfo.systemUptime
            let prior = count
            while count < target {
                let end = min(count + 500, target)
                var entries: [String: String] = [:]
                for i in count..<end { entries[key(i)] = "Translation \(i)." }
                revision += 1
                _ = try await store.save(entries, revision: revision)
                count = end
            }
            let insertMs = (ProcessInfo.processInfo.systemUptime - writeStart) * 1000 / Double(count - prior)
            var samples: [Double] = []
            var misses = 0
            for i in 0..<min(200, target) {
                let index = (i * 7919) % target
                let result = await store.lookup(key: key(index), timeoutMilliseconds: 50)
                samples.append(result.durationMs)
                if result.value == nil { misses += 1 }
            }
            samples.sort()
            func percentile(_ p: Double) -> Double { samples[max(0, Int(ceil(Double(samples.count) * p)) - 1)] }
            let health = try await store.health()
            print("\(target),\(insertMs),\(percentile(0.50)),\(percentile(0.95)),\(misses),\(health.databaseBytes)")
        }
    }
}
