// Screen Translator – App – v0.8.0
// Everything that "understands" text: reading order, speakers, OCR clean-up, slang, protected words.
import Foundation

enum TextIntel {
    // MARK: Reading order
    /// How natural it is to read `lines` in this order (higher = better). Used to detect upside-down frames.
    static func orderScore(_ lines: [String]) -> Double {
        guard lines.count >= 2 else { return 0 }
        let letters = lines.joined().filter(\.isLetter)
        let cased = letters.filter { $0.isUppercase || $0.isLowercase }.count
        // Capitalization cannot establish reading direction for uncased scripts.
        guard cased >= 12, cased * 2 >= letters.count else { return 0 }
        var score = 0.0
        for i in 0..<(lines.count - 1) {
            let a = lines[i].trimmingCharacters(in: .whitespaces)
            let b = lines[i + 1].trimmingCharacters(in: .whitespaces)
            guard let last = a.last, let first = b.first else { continue }
            let endsSentence = ".?!…。！？".contains(last)
            let endsHyphen = last == "-" || last == "–"
            if endsHyphen {
                score += first.isLowercase ? 2 : -1
            } else if endsSentence {
                score += first.isUppercase ? 1 : (first.isLowercase ? -1.5 : 0)
            } else {
                score += first.isLowercase ? 1 : (first.isUppercase ? -0.25 : 0)
            }
        }
        // A paragraph tends to start with a speaker label and end with punctuation
        if let f = lines.first?.trimmingCharacters(in: .whitespaces), speakerLabel(in: f) != nil { score += 1.5 }
        if let l = lines.last?.trimmingCharacters(in: .whitespaces).last, ".?!…。！？\"”".contains(l) { score += 1 }
        return score
    }

    // MARK: Speakers
    private static let startLabel = try! NSRegularExpression(
        pattern: #"^\s*([A-ZÀ-Ý][\p{L}\p{N}.'_\-]{0,19}(?: [A-ZÀ-Ý][\p{L}\p{N}.'_\-]{0,19}){0,2}):\s+"#)
    private static let inlineLabel = try! NSRegularExpression(
        pattern: #"(?:(?<=\s)|^)([A-ZÀ-Ý][\p{L}\p{N}.'_\-]{0,19}(?: [A-ZÀ-Ý][\p{L}\p{N}.'_\-]{0,19}){0,2}):\s"#)

    static func speakerLabel(in s: String) -> String? {
        let ns = s as NSString
        guard let m = startLabel.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// "Rem: hi there Subaru: hello" → [(Rem, "hi there"), (Subaru, "hello")]. Labels are not translated.
    static func splitDialogue(_ text: String) -> [(label: String?, text: String)] {
        let ns = text as NSString
        let ms = inlineLabel.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !ms.isEmpty else { return [(nil, text)] }
        var out: [(label: String?, text: String)] = []
        let first = ms[0].range.location
        if first > 0 {
            let pre = ns.substring(to: first).trimmingCharacters(in: .whitespaces)
            if !pre.isEmpty { out.append((nil, pre)) }
        }
        for (i, m) in ms.enumerated() {
            let label = ns.substring(with: m.range(at: 1))
            let start = m.range.location + m.range.length
            let end = i + 1 < ms.count ? ms[i + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
                .trimmingCharacters(in: .whitespaces)
            out.append((label, body))
        }
        return out.filter { !$0.text.isEmpty }
    }

    // MARK: OCR clean-up
    static func cleanOCR(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<=\p{L})0(?=\p{L})"#, with: "o", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<=\p{L})1(?=\p{L})"#, with: "l", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<![\p{L}\p{N}])0(?=-\p{Ll})"#, with: "O", options: .regularExpression)
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " _~`|•·"))
    }

    /// Numbers-only or symbol-only text ("12 85 72.7") is almost never worth translating.
    static func isNoise(_ s: String) -> Bool {
        let letters = s.filter { $0.isLetter }.count
        let digits = s.filter { $0.isNumber }.count
        return letters < 2 || (digits > 0 && letters * 2 < digits)
    }

    // MARK: Chat slang
    static let slang: [String: [String: String]] = [
        "pt": ["pq": "porque", "vc": "você", "vcs": "vocês", "cê": "você", "tb": "também", "tbm": "também",
               "td": "tudo", "dps": "depois", "msm": "mesmo", "blz": "beleza", "obg": "obrigado",
               "pfv": "por favor", "hj": "hoje", "q": "que", "n": "não", "mt": "muito", "mto": "muito",
               "kd": "cadê", "cmg": "comigo", "ctz": "certeza", "sdds": "saudades", "vdd": "verdade",
               "agr": "agora", "nd": "nada", "oq": "o que", "tá": "está", "tô": "estou", "né": "não é"],
        "es": ["q": "que", "xq": "porque", "pq": "porque", "tb": "también", "tmb": "también", "bn": "bien",
               "xfa": "por favor", "pf": "por favor", "tqm": "te quiero mucho", "dnd": "dónde", "k": "que"],
        "en": ["u": "you", "ur": "your", "pls": "please", "plz": "please", "thx": "thanks", "idk": "I don't know",
               "omg": "oh my god", "btw": "by the way", "rn": "right now", "bc": "because", "cuz": "because",
               "tho": "though", "nvm": "never mind", "gonna": "going to", "wanna": "want to"]
    ]
    private static let wordRegex = try! NSRegularExpression(pattern: #"\p{L}+"#)

    static func expandSlang(_ text: String, lang: String) -> String {
        guard let map = slang[lang] else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for m in wordRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let w = ns.substring(with: m.range)
            if let r = map[w.lowercased()] {
                out += (w.count > 1 && w.first?.isUppercase == true) ? r.prefix(1).uppercased() + r.dropFirst() : r
            } else {
                out += w
            }
            cursor = m.range.location + m.range.length
        }
        return out + ns.substring(from: cursor)
    }

    // MARK: Never-translate words
    static func protect(_ text: String, words: [String]) -> (text: String, tokens: [(String, String)]) {
        var names: [String] = []
        for word in words.prefix(20) where !word.isEmpty {
            if text.range(of: word, options: .caseInsensitive) != nil,
               !names.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
                names.append(word)
            }
        }
        guard !names.isEmpty else { return (text, []) }
        // Match the original once, longest names first. Sequential replacement
        // could modify a placeholder inserted for an earlier protected word.
        let pattern = names.sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return (text, []) }
        let original = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: original.length))
        var out = "", cursor = 0
        var tokens: [(String, String)] = []
        for match in matches {
            let found = original.substring(with: match.range)
            guard let name = names.first(where: { $0.caseInsensitiveCompare(found) == .orderedSame }) else { continue }
            let token: String
            if let existing = tokens.first(where: { $0.1 == name }) { token = existing.0 }
            else {
                var candidate = "Zq" + String(UnicodeScalar(UInt8(97 + tokens.count)))
                // Literal placeholder-like text must survive restoration intact.
                while text.range(of: candidate, options: .caseInsensitive) != nil { candidate += "q" }
                token = candidate
                tokens.append((token, name))
            }
            out += original.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + token
            cursor = match.range.location + match.range.length
        }
        out += original.substring(from: cursor)
        return (out, tokens)
    }

    static func restore(_ text: String, tokens: [(String, String)]) -> String {
        var out = text
        for (token, w) in tokens { out = out.replacingOccurrences(of: token, with: w, options: .caseInsensitive) }
        return out
    }
}
