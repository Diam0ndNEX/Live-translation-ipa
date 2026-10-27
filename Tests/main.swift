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

// A readability hold overlaps translation; only its remainder delays presentation.
check(PresentationSchedule.remaining(policy: "immediate", minimum: 4, lastShown: 10, now: 10.1) == 0, "Immediate mode must add no optional display wait")
check(PresentationSchedule.remaining(policy: "readable", minimum: 2, lastShown: 10, now: 11) == 1, "An 0.8s translation started at 10.2 must consume 0.8s of the hold")
check(PresentationSchedule.remaining(policy: "readable", minimum: 2, lastShown: 10, now: 12.5) == 0, "A completed hold must not delay a ready translation")
check(PresentationSchedule.isCurrent(generation: 2, context: 3, currentGeneration: 2, currentContext: 3, frozen: false, paused: false, manual: false), "A current confirmed result may display")
check(!PresentationSchedule.isCurrent(generation: 1, context: 3, currentGeneration: 2, currentContext: 3, frozen: false, paused: false, manual: false), "A newer OCR result must invalidate pending presentation")
check(!PresentationSchedule.isCurrent(generation: 2, context: 2, currentGeneration: 2, currentContext: 3, frozen: false, paused: false, manual: false), "Language/settings changes must invalidate pending presentation")
check(!PresentationSchedule.isCurrent(generation: 2, context: 3, currentGeneration: 2, currentContext: 3, frozen: true, paused: false, manual: false), "Frozen output must not be overwritten by a delayed result")
check(!PresentationSchedule.isCurrent(generation: 2, context: 3, currentGeneration: 2, currentContext: 3, frozen: false, paused: true, manual: false), "Pause must prevent delayed live output")
check(PresentationSchedule.isCurrent(generation: 2, context: 3, currentGeneration: 2, currentContext: 3, frozen: false, paused: true, manual: true), "Workspace translation remains possible while live capture is paused")
print("Presentation checks passed: hold overlaps processing; stale, frozen and paused output rejected")

check(PresentationSchedule.inferredPolicy(saved: nil, minimum: 1.5) == "readable", "Legacy comic/preset holds must migrate to readable mode")
check(PresentationSchedule.inferredPolicy(saved: nil, minimum: 0) == "immediate", "Legacy zero hold must remain immediate")
check(PresentationSchedule.inferredPolicy(saved: "immediate", minimum: 2) == "immediate", "An explicit immediate preference must survive backup and restore")
print("Legacy timing preference migration checks passed")

var languageUsage = SourceLanguageUsage()
languageUsage.record("pt", origin: .selected)
languageUsage.record("pt", origin: .selected)
check(languageUsage.counts["pt"] == 2, "A manually selected Portuguese source must populate the graph")
check(languageUsage.origins[.detected] == nil, "Manual selection must not be mislabeled as automatic detection")
languageUsage.record("ja", origin: .detected)
languageUsage.record("ja", origin: .locked)
check(languageUsage.counts["ja"] == 2 && languageUsage.origins[.locked] == 1, "Locked-source inputs must continue to populate the graph")
languageUsage.record("auto", origin: .selected)
languageUsage.record("", origin: .selected)
languageUsage.record("–", origin: .selected)
check(languageUsage.counts.count == 2, "Unresolved placeholders must not create fake language bars")
check(languageUsage.counts.values.reduce(0, +) == languageUsage.origins.values.reduce(0, +), "Source and origin totals must reconcile")
languageUsage = SourceLanguageUsage()
check(languageUsage.counts.isEmpty && languageUsage.origins.isEmpty, "Reset must clear both source counters")
print("Source-language diagnostics regression checks passed")

let standardPolicy = RuntimePolicy(coolMode: false, diagnosticsEnabled: true, detailedRequested: false)
check(standardPolicy.captureInterval(0.12) == 0.12, "Normal cadence must remain unchanged")
let coolPolicy = RuntimePolicy(coolMode: true, diagnosticsEnabled: true, detailedRequested: true)
check(coolPolicy.captureInterval(0.12) == 0.45, "Cool mode caps capture work even on Fast")
check(coolPolicy.captureInterval(0.4) == 0.8, "Cool mode halves configured OCR frequency")
check(!coolPolicy.allowsSpeculation && !coolPolicy.allowsPrewarming, "Cool mode skips optional translation work")
check(!standardPolicy.detailedDiagnostics, "Simple collection must not enable detailed work")
check(!RuntimePolicy(coolMode: false, diagnosticsEnabled: false, detailedRequested: true).detailedDiagnostics, "Master collection switch wins")
var speakers = SpeakerSession()
for part in TextIntel.splitDialogue("Rem: hello Subaru: how are you?") {
    if let name = part.label { speakers.record(name, enabled: true, privateSession: false) }
}
check(speakers.names == ["Rem", "Subaru"], "Recognized speakers appear without export consent")
speakers.record("rem", enabled: true, privateSession: false)
check(speakers.names.count == 2, "Speaker OCR capitalization jitter is deduplicated")
speakers.record("Private", enabled: true, privateSession: true)
speakers.record("Disabled", enabled: false, privateSession: false)
check(speakers.names.count == 2, "Private and disabled collection cannot learn speakers")
check(TextIntel.splitDialogue("Hello there").allSatisfy { $0.label == nil }, "Unlabeled dialogue must not invent speakers")
speakers = SpeakerSession()
check(speakers.names.isEmpty, "Session speaker reset clears names")
print("Cool mode and session speaker checks passed")

for n in 0..<100 { speakers.record("Speaker \(n)", enabled: true, privateSession: false) }
check(speakers.names.count == 60, "Session speaker storage stays bounded")

// Reproduce the trace's en → en lock failure without depending on ML heuristics.
var router = SourceLanguageRouter()
for _ in 0..<8 {
    let choice = router.resolve(hypotheses: ["en": 0.99, "pt": 0.01], target: "en", letters: 40, useLock: true, record: true)
    check(choice?.code == "en" && router.locked == nil, "Target-language sightings can never acquire a source lock")
}
for _ in 0..<4 {
    _ = router.resolve(hypotheses: ["pt": 0.92, "en": 0.08], target: "en", letters: 32, useLock: true, record: false)
}
check(router.locked == nil, "Speculative sightings cannot acquire locks")
for _ in 0..<4 {
    _ = router.resolve(hypotheses: ["pt": 0.92, "en": 0.08], target: "en", letters: 32, useLock: true, record: true)
}
check(router.locked == "pt", "Confirmed consistent sources acquire a lock")
let ambiguous = router.resolve(hypotheses: ["en": 0.6, "pt": 0.4], target: "en", letters: 20, useLock: true, record: true)
check(ambiguous?.code == "pt" && ambiguous?.origin == .locked, "A plausible established source stabilizes ambiguous target-language guesses")
check(SourceLanguageRouter.captureLanguage(selected: "auto", locked: router.locked) == "auto", "Locked translation sources must preserve multilingual OCR")
let changed = router.resolve(hypotheses: ["ko": 0.97, "pt": 0.02, "en": 0.01], target: "en", letters: 8, useLock: true, record: false)
check(changed?.code == "ko" && router.locked == "pt", "Clear short language changes route immediately without speculative mutation")
for _ in 0..<2 {
    let switched = router.resolve(hypotheses: ["ko": 0.97, "pt": 0.02], target: "en", letters: 20, useLock: true, record: true)
    check(switched?.code == "ko", "Release hysteresis must never force the previous language onto clear new input")
}
check(router.locked == "pt", "Two confirmed mismatches retain lock hysteresis")
_ = router.resolve(hypotheses: ["ko": 0.97, "pt": 0.02], target: "en", letters: 20, useLock: true, record: true)
check(router.locked == nil, "Three confirmed mismatches release a lock; speculative mismatch did not count")
let actual = router.resolve(hypotheses: ["ko": 0.78, "pt": 0.20, "en": 0.02], target: "en", letters: 24, useLock: false, record: true)
check(actual?.code == "ko", "A lower-probability installed source must not displace the strongest language evidence")
for source in ["pt", "es", "fr", "de", "ja", "ko", "zh-Hant", "ar"] {
    check(!SourceLanguageRouter.shouldDropTarget(selected: source, target: "en", hypotheses: ["en": 0.99], letters: 50), "Explicit source selection survives language-guess vetoes")
    check(SourceLanguageRouter.captureLanguage(selected: source, locked: "pt") == source, "Explicit OCR hint must honor the selected language")
}
check(!SourceLanguageRouter.shouldDropTarget(selected: "auto", target: "en", hypotheses: ["en": 0.99], letters: 10), "Short source phrases must not be discarded on a language guess")
check(SourceLanguageRouter.shouldDropTarget(selected: "auto", target: "en", hypotheses: ["en": 0.99, "pt": 0.01], letters: 50), "Strong long target-language evidence still filters background text")
router.reset()
check(router.locked == nil, "Changing the selected pair clears source-lock history")
check(TextIntel.orderScore(["안녕하세요", "오늘은 좋은 날입니다."]) == 0, "Capitalization heuristics must not rotate Korean")
check(TextIntel.orderScore(["こんにちは", "今日はいい天気です。"]) == 0, "Capitalization heuristics must not rotate Japanese")
check(TextIntel.orderScore(["你好", "今天天气很好。"]) == 0, "Capitalization heuristics must not rotate Chinese")
check(TextIntel.orderScore(["مرحبا", "كيف حالك اليوم؟"]) == 0, "Capitalization heuristics must not rotate Arabic")
check(TextIntel.orderScore(["Hello my friend", "how are you today?"]) > TextIntel.orderScore(["how are you today?", "Hello my friend"]), "Cased-language reading-order evidence remains available")
print("Multilingual source routing regression checks passed")
