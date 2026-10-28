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
var segmentation = SegmentationCache(capacity: 2)
segmentation.insert("pt/en:Olá mundo!", units: ["Olá mundo!"])
segmentation.insert("pt/en:Como vai?", units: ["Como vai?"])
check(segmentation.lookup("pt/en:Olá mundo!") == ["Olá mundo!"], "Repeated segmentation should reuse bounded in-memory result")
segmentation.insert("pt/en:Nova frase", units: ["Nova frase"])
check(segmentation.count == 2 && segmentation.lookup("pt/en:Como vai?") == nil,
      "Segmentation LRU must evict the least recently used entry")
check(segmentation.lookup("pt/en:Olá mundo!") == ["Olá mundo!"],
      "Cache eviction must preserve most recent segmentation")
segmentation.clear()
check(segmentation.count == 0, "Explicit RAM clear must drop temporary segmentation results")
print("Bounded segmentation cache regression checks passed")
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
// Shadow OCR sometimes reports the same subtitle twice at effectively the
// same screen coordinates. This must not multiply translation units.
let shadowA = OCRLine(t: "Olá, amigo!", x: 0.45, y: 0.21, h: 0.035, w: 0.25, confidence: 0.65)
let shadowB = OCRLine(t: "Olá, amigo!", x: 0.451, y: 0.211, h: 0.035, w: 0.25, confidence: 0.94)
let distantRepeat = OCRLine(t: "Olá, amigo!", x: 0.45, y: 0.08, h: 0.035, w: 0.25, confidence: 0.91)
let deduplicated = OCRGrouping.removeNearbyDuplicates([shadowA, shadowB, distantRepeat])
check(deduplicated.count == 2, "Only spatially coincident OCR copies may be suppressed")
check(deduplicated.first?.confidence == 0.94, "Keep the higher-confidence OCR observation")
check(OCRGrouping.makeBlocks([shadowA, shadowB], movie: true).flatMap { $0 }.count == 1,
      "Movie mode removes near-duplicate subtitle shadows")
check(OCRGrouping.makeBlocks([shadowA, shadowB], movie: false).flatMap { $0 }.count == 2,
      "Comic mode must preserve independently observed text")
check(OCRGrouping.makeBlocks([shadowA, distantRepeat], movie: true).flatMap { $0 }.count == 2,
      "Distant repeated dialogue is not a near-duplicate")
print("OCR grouping checks passed")

check(ExportFormat.csv([["hello, world", "a\"b", "line\nbreak"]]) == "\"hello, world\",\"a\"\"b\",\"line\nbreak\"", "CSV must preserve commas, quotes and line breaks")
check(ExportFormat.csvCell("=SUM(A1:A2)") == "\"'=SUM(A1:A2)\"", "CSV must not execute spreadsheet formulas")
check(ExportFormat.csvCell("  +1") == "\"'  +1\"", "Leading spaces must not bypass CSV formula protection")
check(ExportFormat.normalizedArea(0.8, 0.2) == 0.2...0.8, "Reversed capture sliders must produce the intended band")
check(ExportFormat.normalizedArea(-1, 2) == 0...1, "Capture area must stay within the screen")
check(abs(ExportFormat.normalizedArea(0.5, 0.5).upperBound - 0.6) < 0.00001, "Capture area must have a usable minimum height")
print("Export and capture-area checks passed")

// v1.4.1: short subtitles must not be hidden by whole-screen mean differences.
let quietSignature = Array(repeating: UInt8(120), count: 576)
var sparseSubtitle = quietSignature
sparseSubtitle[14] = 184
sparseSubtitle[15] = 184
check(SubtitleAcquisitionPolicy.changed(previous: quietSignature, current: sparseSubtitle),
      "Two high-contrast changed samples must wake OCR even if global average is low")
check(!SubtitleAcquisitionPolicy.changed(previous: quietSignature, current: quietSignature),
      "Unchanged frames may be skipped within a bounded deadline")
check(SubtitleAcquisitionPolicy.changed(previous: [], current: quietSignature),
      "The first sampled frame must always be recognized")
check(SubtitleAcquisitionPolicy.maximumUnchangedDelay(movie: true) < 0.6,
      "Movie subtitles must not wait up to two seconds for an OCR retry")
check(SubtitleAcquisitionPolicy.idleMultiplier(movie: true, enabled: true, secondsSinceText: 10) < 1.3,
      "Movie capture should not slow down 2.5x after a quiet scene")
check(SubtitleAcquisitionPolicy.idleMultiplier(movie: false, enabled: true, secondsSinceText: 10) == 2.5,
      "Other reading modes retain the previous power-saving policy")
check(SubtitleAcquisitionPolicy.idleMultiplier(movie: true, enabled: false, secondsSinceText: 10) == 1,
      "Disabling idle backoff must always mean no idle slow-down")
check(!SubtitleAcquisitionPolicy.shouldSupersedeActive(activeConfirmed: true, incomingConfirmed: false),
      "A tentative subtitle cannot cancel a confirmed translation")
check(SubtitleAcquisitionPolicy.shouldSupersedeActive(activeConfirmed: true, incomingConfirmed: true),
      "A confirmed new subtitle may replace stale confirmed output")
check(SubtitleAcquisitionPolicy.shouldSupersedeActive(activeConfirmed: false, incomingConfirmed: false),
      "Early OCR may update other unconfirmed candidates")
print("Subtitle acquisition and confirmed-caption continuity checks passed")

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

let clearFeedback = RecognitionFeedback(confidence: 0.99, textHeight: 0.05, processingMs: 70, failures: 0, unchangedSeconds: 0, motion: 0)
let easyPlan = AdaptiveRecognition.plan(baseEdge: 1400, interval: 0.22, enabled: true, cool: false, pressure: false, feedback: clearFeedback)
check(easyPlan.edge == 1000, "Large clear text may use Fast-level resolution")
let hardFeedback = RecognitionFeedback(confidence: 0.5, textHeight: 0.01, processingMs: 250, failures: 2, unchangedSeconds: 0, motion: 10)
let hardPlan = AdaptiveRecognition.plan(baseEdge: 1400, interval: 0.22, enabled: true, cool: true, pressure: true, feedback: hardFeedback)
check(hardPlan.edge == 2000 && hardPlan.interval >= 0.55, "Difficult text keeps detail while Cool Mode reduces frequency")
let fixedPlan = AdaptiveRecognition.plan(baseEdge: 1400, interval: 0.22, enabled: false, cool: false, pressure: false, feedback: hardFeedback)
check(fixedPlan.edge == 1400 && fixedPlan.interval == 0.22, "Disabling adaptive behavior preserves the fixed profile")
var candidateTracker = SubtitleTracker()
let clearLine = OCRLine(t: "Olá meu amigo", x: 0.5, y: 0.2, h: 0.04, w: 0.4, confidence: 0.99)
let firstTracked = candidateTracker.observe([clearLine], at: 10, required: 2, adaptive: false, spatial: true, deadline: 0.6, minimumConfidence: 0.3)
check(!firstTracked.ready, "Fixed Normal confirmation still waits for a second read")
let secondTracked = candidateTracker.observe([clearLine], at: 10.2, required: 2, adaptive: false, spatial: true, deadline: 0.6, minimumConfidence: 0.3)
check(secondTracked.ready && firstTracked.id == secondTracked.id, "Consistent positioned text keeps its identity and confirms")
let duplicateTracked = candidateTracker.observe([clearLine], at: 10.4, required: 2, adaptive: false, spatial: true, deadline: 0.6, minimumConfidence: 0.3)
check(duplicateTracked.duplicate, "Already confirmed static text is not resent")
var changedLine = clearLine; changedLine.t = "Olá meu inimigo"
let replacement = candidateTracker.observe([changedLine], at: 10.5, required: 2, adaptive: false, spatial: true, deadline: 0.6, minimumConfidence: 0.3)
check(replacement.id != firstTracked.id && !replacement.ready, "Changed subtitle invalidates the previous candidate immediately")
var immediateTracker = SubtitleTracker()
check(immediateTracker.observe([clearLine], at: 0, required: 2, adaptive: true, spatial: true, deadline: 0.6, minimumConfidence: 0.3).ready, "Opt-in exceptionally clear text may confirm immediately")
var carefulTracker = SubtitleTracker()
check(!carefulTracker.observe([clearLine], at: 0, required: 3, adaptive: true, spatial: true, deadline: 0.6, minimumConfidence: 0.3).ready, "Careful mode cannot immediately confirm a single reading")
var uncertainTracker = SubtitleTracker()
var uncertainLine = clearLine; uncertainLine.confidence = 0.66
check(!uncertainTracker.observe([uncertainLine], at: 0, required: 3, adaptive: true, spatial: true, deadline: 0.6, minimumConfidence: 0.3).ready, "A deadline does not admit a lone uncertain sighting")
check(uncertainTracker.observe([uncertainLine], at: 0.7, required: 3, adaptive: true, spatial: true, deadline: 0.6, minimumConfidence: 0.3).ready, "Deadline can release two stable sufficiently confident reads")
var lowTracker = SubtitleTracker(); uncertainLine.confidence = 0.4
_ = lowTracker.observe([uncertainLine], at: 0, required: 3, adaptive: true, spatial: true, deadline: 0.6, minimumConfidence: 0.3)
check(!lowTracker.observe([uncertainLine], at: 10, required: 3, adaptive: true, spatial: true, deadline: 0.6, minimumConfidence: 0.3).ready, "A stale low-confidence candidate cannot be forced through by a deadline")
check(SpeculationPolicy.credible(lines: [clearLine], threshold: 0.85), "Clear early text may speculate")
check(!SpeculationPolicy.credible(lines: [uncertainLine], threshold: 0.85), "Uncertain early reads must not spend translation work")
var configA = Config(lang: "auto", y0: 0, y1: 1, maxEdge: 1400, interval: 0.22, paused: false)
var configB = configA; configB.pressure = true; configB.interval = 0.4
check(!configB.resetsRecognition(comparedTo: configA), "Runtime workload changes must not reset confirmation")
configB.lang = "ko"
check(configB.resetsRecognition(comparedTo: configA), "A recognition language change must reset old confirmation")
let contextA = PipelineSafety.cacheKey(source: "pt", target: "en", text: "Olá", protectedWords: [], rules: "rules-a")
let contextB = PipelineSafety.cacheKey(source: "pt", target: "en", text: "Olá", protectedWords: [], rules: "rules-b")
check(contextA != contextB, "Language/glossary context namespaces prevent stale translation memory hits")
let memoryRoundtrip = try! JSONDecoder().decode(MemoryEnvelope.self, from: JSONEncoder().encode(MemoryEnvelope(entries: [contextA: "Hello", "legacy": "old", contextB: "   "])))
check(memoryRoundtrip.validated == [contextA: "Hello"], "Only nonempty versioned translations load from persistent memory")
var regions = SubtitleRegions()
var copyLine = clearLine; copyLine.y = 0.8
let regionCopies = regions.deduplicated([[clearLine], [copyLine]])
check(regionCopies.count == 1, "Whole duplicate subtitle regions are coalesced")
let repeatedLyrics = regions.deduplicated([[clearLine, copyLine]])
check(repeatedLyrics.count == 1 && repeatedLyrics[0].count == 2, "Repeated lyric rows inside a visible group remain intact")
var recorderCosts = RecorderCosts(); recorderCosts.record(ms: 2, detailed: false); recorderCosts.record(ms: 7, detailed: true)
check(recorderCosts.simpleMs == 2 && recorderCosts.detailedMs == 7 && recorderCosts.simpleCalls == 1, "Recorder time is separated by actual collection mode")
let oldLine = try! JSONDecoder().decode(OCRLine.self, from: Data(#"{"t":"legacy","x":0.5,"y":0.2,"h":0.03}"#.utf8))
check(oldLine.confidence == nil, "Optional confidence metadata remains backward-compatible")
print("Adaptive pipeline, tracking, speculation and memory regression checks passed")

check(!MemoryRetentionPolicy.mayPersist(privateSession: true, selectedSource: true, confidence: 1, confirmed: true), "Private translations cannot become persistent after private mode ends")
check(!MemoryRetentionPolicy.mayPersist(privateSession: false, selectedSource: true, confidence: 1, confirmed: false), "Speculative text is not retained before confirmation")
check(!MemoryRetentionPolicy.mayPersist(privateSession: false, selectedSource: false, confidence: 0.4, confirmed: true), "Uncertain Automatic sources stay out of persistent memory")
check(MemoryRetentionPolicy.mayPersist(privateSession: false, selectedSource: true, confidence: 0, confirmed: true), "Confirmed explicit sources may persist")
check(!CandidateValidity.isCurrent("old", active: "new", enabled: true), "A superseded candidate cannot store or present results")
check(CandidateValidity.isCurrent("same", active: "same", enabled: true), "Current confirmed work can publish")
check(CandidateValidity.isCurrent(nil, active: "new", enabled: true, allowLegacy: true), "Manual/legacy presentation retains its existing generation checks")
let memoryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenLingo-tests-" + UUID().uuidString)
let memoryFile = memoryDirectory.appendingPathComponent("memory.json")
let memoryWriter = MemoryWriter()
let firstSave = await memoryWriter.save([contextA: "Hello"], to: memoryFile, revision: 2)
check(firstSave, "The memory writer creates Application Support-style directories")
let writtenEnvelope = try! JSONDecoder().decode(MemoryEnvelope.self, from: Data(contentsOf: memoryFile))
check(writtenEnvelope.validated == [contextA: "Hello"], "Versioned memory survives a real disk roundtrip")
await memoryWriter.clear(memoryFile, revision: 3)
_ = await memoryWriter.save([contextA: "stale"], to: memoryFile, revision: 2)
check(!FileManager.default.fileExists(atPath: memoryFile.path), "A stale asynchronous save cannot resurrect cleared memory")
try? FileManager.default.removeItem(at: memoryDirectory)
print("Persistence, privacy and candidate-lifetime regression checks passed")

var rotationBudget = RotationBudget()
check(!RotationBudget.sufficientEvidence(vote:-4.9,samples:20), "Weak case-order votes cannot trigger rotation cycles")
check(RotationBudget.sufficientEvidence(vote:-7,samples:3), "Strong sustained order evidence can start bounded probes")
check(rotationBudget.next() == 2 && rotationBudget.next() == 1 && rotationBudget.next() == 3 && rotationBudget.next() == 0, "Rotation search visits alternatives once then returns to capture orientation")
check(rotationBudget.exhausted && rotationBudget.next() == nil, "Failed orientation probes cannot repeat indefinitely")
var sourceContext = LanguageContext()
sourceContext.record("Olá meu amigo, como você está hoje?",code:"pt",confidence:0.95,now:10)
check(sourceContext.mayAssist(["pt":0.4,"en":0.6],now:12), "Recent reliable source context can stabilize an ambiguous reading")
check(!sourceContext.mayAssist(["ko":0.97,"pt":0.02],now:12), "A clear language switch cannot be overridden by prior context")
check(!sourceContext.mayAssist(["pt":0.4,"en":0.6],now:20), "Old source context expires instead of locking new content")
let simulationOptions = ["source":"pt","target":"en","speed":"fast","stability":"2","subtitleTracking":"true","adaptiveConfirmation":"false","privateSession":"false"]
let simulation = PipelineSimulation.run(options:simulationOptions,input:SimulationInput())
check(simulation.displayAccepted && simulation.steps.count >= 12 && simulation.totalMs > 0, "In-app simulation traverses the complete pipeline without model calls")
var frozenSimulation = SimulationInput();frozenSimulation.frozen=true
check(!PipelineSimulation.run(options:simulationOptions,input:frozenSimulation).displayAccepted, "Frozen simulation cannot publish a modeled caption")
var pausedSimulation = SimulationInput();pausedSimulation.paused=true
check(PipelineSimulation.run(options:simulationOptions,input:pausedSimulation).steps.count == 2, "Paused capture simulation stops before OCR")
var missingPackSimulation = SimulationInput();missingPackSimulation.packReady=false
check(!PipelineSimulation.run(options:simulationOptions,input:missingPackSimulation).displayAccepted, "Missing model packs block fresh simulated translation")
var supersededSimulation = SimulationInput();supersededSimulation.superseded=true
check(!PipelineSimulation.run(options:simulationOptions,input:supersededSimulation).displayAccepted, "A newer unconfirmed candidate rejects outdated simulated work")
var privateOptions=simulationOptions;privateOptions["privateSession"]="true"
let privateSimulation=PipelineSimulation.run(options:privateOptions,input:SimulationInput())
check(privateSimulation.steps.contains { $0.title == "History, persistent memory & feedback" && $0.state == "session only" }, "Simulator explains private retention without writing history or memory")
check(PipelineSimulation.optionGroups.flatMap { $0.1 }.contains("contextualLanguage"), "Source-context control is represented in the simulator")
print("Bounded rotation, context recovery and in-app simulation regression checks passed")

let limitedPlan = AdaptiveRecognition.plan(baseEdge: 550, interval: 0.3, enabled: true, cool: true, pressure: true, feedback: hardFeedback, ceiling: 550)
check(limitedPlan.edge <= 550, "Adaptive detail cannot override a critical-thermal or memory image ceiling")
var lowPowerSimulation=SimulationInput();lowPowerSimulation.lowPower=true
let lowPowerResult=PipelineSimulation.run(options:simulationOptions,input:lowPowerSimulation)
check(lowPowerResult.steps.contains { $0.title == "Speculative-work gate" && $0.state == "wait for confirmation" }, "Low Power Mode disables speculative model work in the simulator")
print("Thermal ceiling and Low Power Mode checks passed")

var sqliteScenario = SimulationInput()
sqliteScenario.cacheOrigin = "sqlite"
sqliteScenario.memoryLookupMs = 3
let sqliteSimulation = PipelineSimulation.run(options: simulationOptions, input: sqliteScenario)
check(sqliteSimulation.steps.contains { $0.title == "Persistent memory decision" && $0.state == "sqlite" }, "Simulator exposes SQLite hit scenario")
sqliteScenario.memoryLookupMs = 20
let deadlineSimulation = PipelineSimulation.run(options: simulationOptions, input: sqliteScenario)
check(deadlineSimulation.steps.contains { $0.title == "Persistent memory decision" && $0.state.contains("deadline exceeded") }, "Simulator models deadline fallback explicitly")
print("Memory lookup simulator checks passed")

let multiSentence = TranslationUnitPlanning.units(source: "Olá. Tudo bem?",
    candidates: ["Olá.", "Tudo bem?"])
check(multiSentence == ["Olá.", "Tudo bem?"], "Confirmed sentence punctuation may create distinct units")
let incompleteLyrics = "Primeira linha\nsegunda linha\nterceira linha"
check(TranslationUnitPlanning.units(source: incompleteLyrics,
    candidates: ["Primeira linha", "segunda linha", "terceira linha"]) == [incompleteLyrics],
    "Incomplete scrolling lyrics must retain their complete line structure")
check(TranslationUnitPlanning.units(source: "Dr. Smith arrived.",
    candidates: ["Dr.", "Smith arrived."]) == ["Dr. Smith arrived."],
    "Abbreviations may not manufacture authoritative independent units")
check(TranslationUnitPlanning.units(source: "He paused... then spoke.",
    candidates: ["He paused...", "then spoke."]) == ["He paused... then spoke."],
    "Unfinished ellipses must preserve subtitle context")
check(TranslationUnitPlanning.units(source: "Eine Sache. Noch etwas.",
    candidates: ["Eine Sache.", "Noch etwas."]) == ["Eine Sache.", "Noch etwas."],
    "Sentence boundaries must preserve original source content")
check(TranslationUnitPlanning.units(source: "Hello world!",
    candidates: ["Hello", "world!"]) == ["Hello world!"],
    "Tokenizer candidates without sentence boundaries must not fragment a sentence")
check(!TranslationUnitPlanning.mayRemember("12 13", confirmed: true),
    "Nonlinguistic OCR must not become an authoritative permanent memory entry")
check(!TranslationUnitPlanning.mayRemember("Hello.", confirmed: false),
    "Unconfirmed speculative text must remain RAM-only")
check(TranslationUnitPlanning.mayRemember("Olá.", confirmed: true),
    "Confirmed language-bearing entries remain eligible for persistence")
print("Translation-unit segmentation, context and persistence safety checks passed")
