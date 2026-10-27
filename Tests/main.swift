import Foundation

func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    guard condition() else { fatalError(description) }
}
check(PipelineSafety.orderedTranslations([("1", "second"), ("0", "first")], count: 2) == ["first", "second"], "Batch identity restores reading order")
let invalidBatches: [[(String?, String)]] = [
    [("-1", "bad")], [("1", "bad")], [(nil, "bad")], [("0", "  ")]
]
for invalid in invalidBatches {
    check(PipelineSafety.orderedTranslations(invalid, count: 1) == nil, "Invalid batch must fail safely")
}
check(PipelineSafety.orderedTranslations([("0", "a"), ("0", "b")], count: 2) == nil, "Duplicate identities must fail")
check(PipelineSafety.orderedTranslations([("0", "a")], count: 2) == nil, "Missing results must fail")
check(PipelineSafety.isRecentFragment("como você está hoje", of: "Olá meu amigo como você está hoje", age: 0.5), "Keep complete subtitle on partial OCR")
check(!PipelineSafety.isRecentFragment("como você está hoje", of: "Olá meu amigo como você está hoje", age: 3), "Allow legitimate later repetition")
check(!PipelineSafety.isRecentFragment("Uma frase completamente nova", of: "Olá meu amigo como você está hoje", age: 0.5), "New dialogue must update immediately")
check(!PipelineSafety.isDuplicate(["First verse", "I love you"], previous: ["First verse", "I hate you"]), "Changed verse must refresh")
check(!PipelineSafety.isDuplicate(["First verse"], previous: ["First verse", "Second verse"]), "Removing a verse must refresh")
check(PipelineSafety.isDuplicate(["Olá, amigo!"], previous: ["Olá amigo"]), "Punctuation jitter should not retranslate")
let a = PipelineSafety.cacheKey(source: "pt", target: "en", text: "Zqa chegou", protectedWords: ["Maria"])
let b = PipelineSafety.cacheKey(source: "pt", target: "en", text: "Zqa chegou", protectedWords: ["Joana"])
check(a != b, "Protected names must have independent cache entries")
print("Pipeline regression checks passed")

let firstHalf = OCRLine(t: "Olá meu amigo", x: 0.30, y: 0.20, h: 0.03, w: 0.30)
let secondHalf = OCRLine(t: "como você está?", x: 0.62, y: 0.201, h: 0.03, w: 0.30)
let subtitle = OCRGrouping.makeBlocks([secondHalf, firstHalf], movie: true)
check(subtitle.count == 1 && subtitle[0].map(\.t) == ["Olá meu amigo", "como você está?"], "Same-row subtitle pieces must read left to right")
check(OCRGrouping.makeBlocks([secondHalf, firstHalf], movie: false).count == 2, "Separate same-row comic bubbles must remain independent")
let nextRow = OCRLine(t: "Uma segunda linha", x: 0.32, y: 0.16, h: 0.03, w: 0.32)
check(OCRGrouping.makeBlocks([nextRow, firstHalf], movie: true).count == 1, "Stacked subtitle lines preserve sentence context")
let distantRow = OCRLine(t: "Outro diálogo", x: 0.3, y: 0.05, h: 0.03, w: 0.3)
check(OCRGrouping.makeBlocks([distantRow, firstHalf], movie: true).count == 2, "Distant text must not bridge dialogue regions")
print("OCR grouping checks passed")

check(ExportFormat.csv([["hello, world", "a\"b", "line\nbreak"]]) == "\"hello, world\",\"a\"\"b\",\"line\nbreak\"", "CSV must preserve commas, quotes and line breaks")
check(ExportFormat.csvCell("=SUM(A1:A2)") == "\"'=SUM(A1:A2)\"", "CSV must not execute spreadsheet formulas")
check(ExportFormat.csvCell("  +1") == "\"'  +1\"", "Leading spaces must not bypass CSV formula protection")
check(ExportFormat.normalizedArea(0.8, 0.2) == 0.2...0.8, "Reversed capture sliders must produce the intended band")
check(ExportFormat.normalizedArea(-1, 2) == 0...1, "Capture area must stay within the screen")
check(abs(ExportFormat.normalizedArea(0.5, 0.5).upperBound - 0.6) < 0.00001, "Capture area must have a usable minimum height")
print("Export and capture-area checks passed")

// Cadence removes only redundant waiting: accuracy, pass count and resolution are unchanged.
check(CaptureCadence.remaining(startedAt: 10, now: 10.242, interval: 0.22) == 0, "An OCR pass longer than its interval must not incur a second interval")
check(abs(CaptureCadence.remaining(startedAt: 10, now: 10.1, interval: 0.22) - 0.12) < 0.000001, "Short passes must respect their configured cadence")
let plan = TranslationBatchPlan(["Olá.", "Olá.", "Como vai?", "Olá."])
check(plan.unique == ["Olá.", "Como vai?"], "Only exact repeated sentences may share a request")
check(plan.expand(["Hello.", "How are you?"]) == ["Hello.", "Hello.", "How are you?", "Hello."], "Deduplication must preserve complete sentence order")
check(plan.expand([nil, "How are you?"]) == [nil, nil, "How are you?", nil], "Failures must fan out without partial or fabricated translations")
check(plan.expand(["Wrong count"]) == nil, "Malformed result counts must still fail")
let protected = TranslationBatchPlan(["Zqa chegou.", "Zqa chegou."], contexts: ["Zqa=Maria", "Zqa=Joana"])
check(protected.unique.count == 2, "Different protected-name mappings must never be merged")
check(TranslationBatchPlan(["Olá", "ola"]).unique.count == 2, "No fuzzy reuse or accent normalization is allowed")
var measurements = 0
let fitted = FontSearch.size(high: 72, low: 12) { size in measurements += 1; return size <= 30 }
check(fitted == 30 && measurements <= 5, "Font fitting should find the same size with at most five measurements")
for threshold in stride(from: 10.0, through: 74.0, by: 0.5) {
    let baseline = stride(from: 72.0, through: 12.0, by: -2).first { $0 <= threshold } ?? 12
    let optimized = FontSearch.size(high: 72, low: 12) { $0 <= threshold }
    check(baseline == optimized, "Font search must match the original size grid exactly")
}
let fixture = (0..<1200).map { "Sentence \($0 % 120)." }
let optimizedFixture = TranslationBatchPlan(fixture)
check(optimizedFixture.unique.count == 120, "Repeated-request fixture must reduce 1200 requests to 120")
check(optimizedFixture.expand(optimizedFixture.unique.map(Optional.some)) == fixture.map(Optional.some), "Performance fixture output must exactly match its original order")
print("Latency checks passed: 1200 repeated requests -> 120; font measurements <= 5; cadence removes post-OCR interval")
