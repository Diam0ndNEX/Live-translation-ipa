import Foundation

/// Pure pipeline rules shared by the app and the regression checks.
enum PipelineSafety {
    static func isRecentFragment(_ candidate: String, of previous: String, age: TimeInterval) -> Bool {
        let old = TextSim.norm(previous), new = TextSim.norm(candidate)
        return age < 2 && new.count >= 8 && old.count >= new.count + 8
            && Double(new.count) / Double(max(1, old.count)) < 0.82 && old.contains(new)
    }

    static func isDuplicate(_ blocks: [String], previous: [String]) -> Bool {
        // Compare each row: a changed short verse must survive even when most of the page is unchanged.
        guard blocks.count == previous.count else { return false }
        return zip(blocks, previous).allSatisfy { TextSim.similar($0.0, $0.1, 0.97) }
    }

    static func cacheKey(source: String, target: String, text: String, protectedWords: [String]) -> String {
        // Length-prefixed metadata prevents different protected names sharing the same placeholder cache entry.
        let context = protectedWords.map { "\($0.utf8.count):\($0)" }.joined()
        return "v2|\(source)>\(target)|\(context.utf8.count):\(context)|\(text)"
    }

    static func orderedTranslations(_ responses: [(String?, String)], count: Int) -> [String]? {
        guard responses.count == count else { return nil }
        var output = [String?](repeating: nil, count: count)
        for (identifier, text) in responses {
            guard let identifier, let index = Int(identifier), output.indices.contains(index),
                  output[index] == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            output[index] = text
        }
        guard output.allSatisfy({ $0 != nil }) else { return nil }
        return output.compactMap { $0 }
    }
}
