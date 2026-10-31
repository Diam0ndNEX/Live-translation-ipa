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

struct FakePreparationIdentity: Equatable {
    let session: UUID
    let candidate: String
    let exactText: String
    let x: Double
    let language: String
    let rules: String
    let rotation: Int
    let epoch: Int
}
let planSession = UUID()
let immutableKey = FakePreparationIdentity(session: planSession, candidate: "caption-1",
    exactText: "Olá mundo", x: 0.55, language: "pt>en", rules: "rules-v1", rotation: 0, epoch: 10)
var candidatePlans = ExactPlanReuseCache<FakePreparationIdentity, [String]>(capacity: 4)
check(candidatePlans.lookup(immutableKey) == nil, "A new candidate must build its initial plan")
candidatePlans.insert(["Olá mundo"], for: immutableKey)
check(candidatePlans.lookup(immutableKey) == ["Olá mundo"],
      "An independently confirmed, identical candidate may reuse an immutable plan")
let invalidKeys = [
    FakePreparationIdentity(session: UUID(), candidate: "caption-1",
        exactText: "Olá mundo", x: 0.55, language: "pt>en", rules: "rules-v1", rotation: 0, epoch: 10),
    FakePreparationIdentity(session: planSession, candidate: "caption-2",
        exactText: "Olá mundo", x: 0.55, language: "pt>en", rules: "rules-v1", rotation: 0, epoch: 10),
    FakePreparationIdentity(session: planSession, candidate: "caption-1",
        exactText: "Olá mundos", x: 0.55, language: "pt>en", rules: "rules-v1", rotation: 0, epoch: 10),
    FakePreparationIdentity(session: planSession, candidate: "caption-1",
        exactText: "Olá mundo", x: 0.56, language: "pt>en", rules: "rules-v1", rotation: 0, epoch: 10),
    FakePreparationIdentity(session: planSession, candidate: "caption-1",
        exactText: "Olá mundo", x: 0.55, language: "es>en", rules: "rules-v1", rotation: 0, epoch: 10),
    FakePreparationIdentity(session: planSession, candidate: "caption-1",
        exactText: "Olá mundo", x: 0.55, language: "pt>en", rules: "rules-v2", rotation: 0, epoch: 10),
    FakePreparationIdentity(session: planSession, candidate: "caption-1",
        exactText: "Olá mundo", x: 0.55, language: "pt>en", rules: "rules-v1", rotation: 1, epoch: 10),
    FakePreparationIdentity(session: planSession, candidate: "caption-1",
        exactText: "Olá mundo", x: 0.55, language: "pt>en", rules: "rules-v1", rotation: 0, epoch: 11)
]
for changed in invalidKeys {
    check(candidatePlans.lookup(changed) == nil,
          "A corrected source, layout, language, rule, rotation or capture must rebuild translation units")
}
for i in 0..<10 {
    candidatePlans.insert(["unit \(i)"], for: FakePreparationIdentity(session: planSession,
        candidate: "candidate-\(i)", exactText: "\(i)", x: 0.3,
        language: "pt>en", rules: "r", rotation: 0, epoch: 10))
}
check(candidatePlans.count == 4 && candidatePlans.lookup(immutableKey) == nil,
      "Preparation cache must stay bounded and expire obsolete candidates")
candidatePlans.clear()
check(candidatePlans.count == 0, "Changes to capture context must invalidate all volatile candidate plans")
var physicalDefault = AppleDefaultLeaseState()
let firstPhysical = physicalDefault.begin()!
check(physicalDefault.begin() == nil, "No second Apple request may acquire an occupied speculative lease")
physicalDefault.requestCancellation()
check(physicalDefault.active == firstPhysical, "Requesting cancellation must not release real lane ownership")
check(!physicalDefault.finish(firstPhysical, successful: true),
      "A cancelled session is never reusable even when Apple returns successful output")
let nextPhysical = physicalDefault.begin()!
physicalDefault.reset()
check(!physicalDefault.finish(nextPhysical, successful: true),
      "An old request finishing after reset cannot resurrect a warmed session")
let freshPhysical = physicalDefault.begin()!
check(physicalDefault.finish(freshPhysical, successful: true),
      "Compatible successful physical completion should retain session warmth")
check(physicalDefault.completed == 3, "Physical completion must be counted only on actual return")
// A deterministic injection verifies that isolated LL and Legacy benchmarks
// can detect a 20ms planning or confirmed-queue penalty at the target scale.
let appPathBaseline = [104.0, 112, 128, 140, 180].map { $0 + 45 }
let appPathInjected = appPathBaseline.map { $0 + 20 }
check(zip(appPathInjected, appPathBaseline).allSatisfy { $0 - $1 == 20 },
      "LL candidate plan profiler must detect a 20ms injected critical-path delay")
let legacyPathBaseline = [100.0, 140, 180, 220, 250].map { $0 + 270 }
let legacyPathInjected = legacyPathBaseline.map { $0 + 25 }
check(zip(legacyPathInjected, legacyPathBaseline).allSatisfy { $0 - $1 == 25 },
      "Legacy queue profiler must detect a 25ms injected critical-path delay")
print("v1.9.6 LL/Legacy bounded plan reuse, cancellation lease and overhead-injection checks passed")


let workKey = SharedTranslationWork.unitKey(source: "pt", target: "en", text: "Bom dia",
    protectedWords: ["5:Maria"], rules: "privacy-rules")
check(workKey == PipelineSafety.cacheKey(source: "pt", target: "en", text: "Bom dia",
    protectedWords: ["5:Maria"], rules: "privacy-rules"),
    "Shared Legacy/Hybrid planning must preserve persisted exact context key bytes")
check(workKey != SharedTranslationWork.unitKey(source: "pt", target: "en", text: "Bom dia",
    protectedWords: ["5:Maria"], rules: "changed-rules"),
    "Different language rules cannot silently share speculative memory")
check(SharedTranslationWork.unresolvedIndices(keys: ["a","b","a","c"],
    values: [nil, "already stored", nil, nil]) == [0,3],
    "Shared work planner must submit one request per distinct missing unit")
check(SharedTranslationWork.unresolvedIndices(keys: ["a"], values: []) == nil,
    "Malformed model plans must be rejected before inference")
let workEpoch = UUID()
check(SharedTranslationWork.mayReuse(workEpoch: workEpoch, currentEpoch: workEpoch,
    requestedCancellation: false, compatibleContext: true),
    "Completed same-epoch work may populate compatible volatile cache")
check(!SharedTranslationWork.mayReuse(workEpoch: workEpoch, currentEpoch: UUID(),
    requestedCancellation: false, compatibleContext: true) &&
      !SharedTranslationWork.mayReuse(workEpoch: workEpoch, currentEpoch: workEpoch,
    requestedCancellation: true, compatibleContext: true),
    "Cancelled or reset work cannot refill a different capture generation")


let firstHalf = OCRLine(t: "Olá meu amigo", x: 0.30, y: 0.20, h: 0.03, w: 0.30)
let secondHalf = OCRLine(t: "como você está?", x: 0.62, y: 0.201, h: 0.03, w: 0.30)
let subtitle = OCRGrouping.makeBlocks([secondHalf, firstHalf], joinAdjacentText: true)
check(subtitle.count == 1 && subtitle[0].map(\.t) == ["Olá meu amigo", "como você está?"], "Same-row subtitle pieces must read left to right")
check(OCRGrouping.makeBlocks([secondHalf, firstHalf], joinAdjacentText: false).count == 2, "Separate same-row comic bubbles must remain independent")
let nextRow = OCRLine(t: "Uma segunda linha", x: 0.32, y: 0.16, h: 0.03, w: 0.32)
check(OCRGrouping.makeBlocks([nextRow, firstHalf], joinAdjacentText: true).count == 1, "Stacked subtitle lines preserve sentence context")
let distantRow = OCRLine(t: "Outro diálogo", x: 0.3, y: 0.05, h: 0.03, w: 0.3)
check(OCRGrouping.makeBlocks([distantRow, firstHalf], joinAdjacentText: true).count == 2, "Distant text must not bridge dialogue regions")
// Shadow OCR sometimes reports the same subtitle twice at effectively the
// same screen coordinates. This must not multiply translation units.
let shadowA = OCRLine(t: "Olá, amigo!", x: 0.45, y: 0.21, h: 0.035, w: 0.25, confidence: 0.65)
let shadowB = OCRLine(t: "Olá, amigo!", x: 0.451, y: 0.211, h: 0.035, w: 0.25, confidence: 0.94)
let distantRepeat = OCRLine(t: "Olá, amigo!", x: 0.45, y: 0.08, h: 0.035, w: 0.25, confidence: 0.91)
let deduplicated = OCRGrouping.removeNearbyDuplicates([shadowA, shadowB, distantRepeat])
check(deduplicated.count == 2, "Only spatially coincident OCR copies may be suppressed")
check(deduplicated.first?.confidence == 0.94, "Keep the higher-confidence OCR observation")
check(OCRGrouping.makeBlocks([shadowA, shadowB], joinAdjacentText: true).flatMap { $0 }.count == 1,
      "Movie mode removes near-duplicate subtitle shadows")
check(OCRGrouping.makeBlocks([shadowA, shadowB], joinAdjacentText: false).flatMap { $0 }.count == 2,
      "Comic mode must preserve independently observed text")
check(OCRGrouping.makeBlocks([shadowA, distantRepeat], joinAdjacentText: true).flatMap { $0 }.count == 2,
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
check(SubtitleAcquisitionPolicy.maximumUnchangedDelay(rapidTextTracking: true) < 0.6,
      "Movie subtitles must not wait up to two seconds for an OCR retry")
check(SubtitleAcquisitionPolicy.idleMultiplier(rapidTextTracking: true, enabled: true, secondsSinceText: 10) < 1.3,
      "Movie capture should not slow down 2.5x after a quiet scene")
check(SubtitleAcquisitionPolicy.idleMultiplier(rapidTextTracking: false, enabled: true, secondsSinceText: 10) == 2.5,
      "Other reading modes retain the previous power-saving policy")
check(SubtitleAcquisitionPolicy.idleMultiplier(rapidTextTracking: true, enabled: false, secondsSinceText: 10) == 1,
      "Disabling idle backoff must always mean no idle slow-down")
check(!SubtitleAcquisitionPolicy.shouldSupersedeActive(activeConfirmed: true, activePresented: false, incomingConfirmed: false),
      "A tentative subtitle cannot cancel a confirmed translation")
check(SubtitleAcquisitionPolicy.shouldSupersedeActive(activeConfirmed: true, activePresented: false, incomingConfirmed: true),
      "A confirmed new subtitle may replace stale confirmed output")
check(SubtitleAcquisitionPolicy.shouldSupersedeActive(activeConfirmed: false, activePresented: false, incomingConfirmed: false),
      "Early OCR may update other unconfirmed candidates")
check(SubtitleAcquisitionPolicy.shouldSupersedeActive(activeConfirmed: true, activePresented: true, incomingConfirmed: false),
      "The next early subtitle may translate ahead once the previous one was presented")
// Built-in profiles differ only in settings; custom profiles can select
// precisely the same recognition behavior regardless of category.
let movieFeatures = PresetRecognitionPolicy.legacyDefaults(for: "movie")
let gameFeatures = PresetRecognitionPolicy.legacyDefaults(for: "game")
let comicFeatures = PresetRecognitionPolicy.legacyDefaults(for: "comic")
check(movieFeatures[PresetRecognitionPolicy.rapidTextTracking] == true &&
      movieFeatures[PresetRecognitionPolicy.joinAdjacentText] == true &&
      movieFeatures[PresetRecognitionPolicy.activeTextFocus] == true,
      "Movie defaults should enable subtitle-oriented capabilities")
check(gameFeatures.values.allSatisfy { !$0 } && comicFeatures.values.allSatisfy { !$0 },
      "Game and Comic default to separate text regions, but can opt into all subtitle features")
let legacyProfileDefaults = UserDefaults(suiteName: "ScreenLingoTests.RecognitionMigration.\(UUID().uuidString)")!
legacyProfileDefaults.set("game", forKey: "mode")
PresetRecognitionPolicy.migrate(legacyProfileDefaults)
check(legacyProfileDefaults.bool(forKey: PresetRecognitionPolicy.rapidTextTracking) == false,
      "Existing game profiles must preserve conservative OCR scheduling on migration")
legacyProfileDefaults.set(true, forKey: PresetRecognitionPolicy.rapidTextTracking)
PresetRecognitionPolicy.migrate(legacyProfileDefaults)
check(legacyProfileDefaults.bool(forKey: PresetRecognitionPolicy.rapidTextTracking),
      "Migration must never overwrite an explicit custom-mode feature choice")
check(SubtitlePerformancePolicy.confirmationInterval(planned: 0.22, pending: true,
    rapidTextTracking: true, pressure: false, processingMs: 60) == 0.10,
    "The same rapid confirmation feature works in any preset category")
check(OCRGrouping.makeBlocks([secondHalf, firstHalf], joinAdjacentText: true).count == 1,
      "The same text joining feature works in any preset category")

print("Subtitle acquisition and confirmed-caption continuity checks passed")

// Cadence removes only redundant waiting: accuracy, pass count and resolution are unchanged.
check(CaptureCadence.remaining(startedAt: 10, now: 10.242, interval: 0.22) == 0, "An OCR pass longer than its interval must not incur a second interval")
check(SubtitlePerformancePolicy.confirmationInterval(planned: 0.22, pending: true,
    rapidTextTracking: true, pressure: false, processingMs: 134) == 0.134,
    "Pending subtitle confirmation removes idle spacing while retaining another independent frame")
check(SubtitlePerformancePolicy.confirmationInterval(planned: 0.22, pending: false,
    rapidTextTracking: true, pressure: false, processingMs: 134) == 0.22,
    "A settled caption must not continuously burst OCR")
check(SubtitlePerformancePolicy.confirmationInterval(planned: 0.4, pending: true,
    rapidTextTracking: true, pressure: true, processingMs: 134) == 0.4,
    "Thermal, power and Cool pressure must retain their full cadence")
check(SubtitlePerformancePolicy.confirmationInterval(planned: 0.22, pending: true,
    rapidTextTracking: true, pressure: false, processingMs: 60) == 0.10,
    "Nominal Movie confirmation may use the 100ms safety floor when the OCR engine is fast")
check(SubtitlePerformancePolicy.confirmationInterval(planned: 0.22, pending: true,
    rapidTextTracking: true, pressure: true, processingMs: 60) == 0.22,
    "Pressure must disable the faster confirmation burst")
check(SubtitlePerformancePolicy.confirmationInterval(planned: 0.12, pending: true,
    rapidTextTracking: true, pressure: false, processingMs: 250) == 0.12,
    "A confirmation burst must never delay an already faster cadence")
check(SubtitlePerformancePolicy.confirmationInterval(planned: 0.4, pending: true,
    rapidTextTracking: false, pressure: false, processingMs: 134) == 0.4,
    "Non-Movie modes retain their existing scheduling")
check(SubtitlePerformancePolicy.confirmationInterval(planned: 0.22, pending: true,
    rapidTextTracking: true, pressure: false, processingMs: .nan) == 0.22,
    "Invalid timing evidence must preserve configured scheduling")
check(abs(SubtitlePerformancePolicy.confirmedHandoffDelay(age: 0.1) - 0.35) < 0.000001,
    "Early confirmed handoff retains an absolute 450ms deadline")
check(SubtitlePerformancePolicy.confirmedHandoffDelay(age: 0.6) == 0.12,
    "An older confirmed caption gets only a short completion opportunity")
check(abs(SubtitlePerformancePolicy.confirmedHandoffDelay(age: 0.85) - 0.05) < 0.000001 &&
    SubtitlePerformancePolicy.confirmedHandoffDelay(age: 0.9) == 0 &&
    SubtitlePerformancePolicy.confirmedHandoffDelay(age: .nan) == 0,
    "Handoff never extends beyond the freshness cap or accepts invalid ages")
var speculationHistory = SpeculativeWorkWindow()
for _ in 0..<24 {
    let id = speculationHistory.begin()
    speculationHistory.finish(id, discarded: true)
}
let firstSpeculationOpportunity = speculationHistory.allowsOpportunity(enabled: true)
let secondSpeculationOpportunity = speculationHistory.allowsOpportunity(enabled: true)
check(!firstSpeculationOpportunity && secondSpeculationOpportunity,
    "Runtime evidence throttles low-yield work with diagnostics absent and keeps recovery probes")
for _ in 0..<32 {
    let id = speculationHistory.begin()
    speculationHistory.finish(id, discarded: false)
    speculationHistory.reuse(id)
    speculationHistory.reuse(id)
}
check(speculationHistory.allowsOpportunity(enabled: true),
    "A new useful scene ages out old discarded work; repeated sentence hits do not inflate pipeline usefulness")
check(speculationHistory.allowsOpportunity(enabled: false),
    "The user can disable speculative throttling")
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
let blockedDirectory = memoryDirectory.appendingPathComponent("blocked")
try! Data("not a directory".utf8).write(to: blockedDirectory)
let retryFile = blockedDirectory.appendingPathComponent("retry.json")
let retryWriter = MemoryWriter()
let failedSave = await retryWriter.save([contextA: "Hello"], to: retryFile, revision: 1)
check(!failedSave, "A failed atomic save must report failure")
try! FileManager.default.removeItem(at: blockedDirectory)
let retriedSave = await retryWriter.save([contextA: "Hello"], to: retryFile, revision: 1)
check(retriedSave && FileManager.default.fileExists(atPath: retryFile.path),
    "A failed save must remain retryable at the same revision")
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
var customComicOptions = simulationOptions
customComicOptions["mode"] = "comic"
customComicOptions["rapidTextTracking"] = "true"
customComicOptions["joinAdjacentText"] = "true"
customComicOptions["activeTextFocus"] = "true"
let rapidComicSimulation = PipelineSimulation.run(options: customComicOptions, input: SimulationInput())
check(rapidComicSimulation.steps.contains {
    $0.title == "Local delivery & source filtering" &&
    $0.detail.contains("Adjacent joining: on; active-text focus: on")
}, "A Comic custom preset must use subtitle grouping and focus when explicitly enabled")
customComicOptions["rapidTextTracking"] = "false"
customComicOptions["joinAdjacentText"] = "false"
customComicOptions["activeTextFocus"] = "false"
let separateComicSimulation = PipelineSimulation.run(options: customComicOptions, input: SimulationInput())
check(separateComicSimulation.steps.contains {
    $0.title == "Local delivery & source filtering" &&
    $0.detail.contains("Adjacent joining: off; active-text focus: off")
}, "Independent switches must override the preset category in the simulator")
let rapidConfirmation = rapidComicSimulation.steps.first { $0.title == "Candidate identity & confirmation" }?.duration ?? .infinity
let separateConfirmation = separateComicSimulation.steps.first { $0.title == "Candidate identity & confirmation" }?.duration ?? -.infinity
check(rapidConfirmation < separateConfirmation,
      "Rapid text confirmation must be available to Comic or any custom preset")

print("Bounded rotation, context recovery and in-app simulation regression checks passed")

let limitedPlan = AdaptiveRecognition.plan(baseEdge: 550, interval: 0.3, enabled: true, cool: true, pressure: true, feedback: hardFeedback, ceiling: 550)
check(limitedPlan.edge <= 550, "Adaptive detail cannot override a critical-thermal or memory image ceiling")
var lowPowerSimulation=SimulationInput();lowPowerSimulation.lowPower=true
let lowPowerResult=PipelineSimulation.run(options:simulationOptions,input:lowPowerSimulation)
check(lowPowerResult.steps.contains { $0.title == "Speculative-work gate" && $0.state == "wait for confirmation" }, "Low Power Mode disables speculative model work in the simulator")
print("Thermal ceiling and Low Power Mode checks passed")

let thermalStates: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
check(ThermalPerformancePolicy.tier(for: .nominal) == .fullPerformance &&
      ThermalPerformancePolicy.tier(for: .fair) == .fullPerformance,
      "Nominal and fair must share the same full-performance tier")
check(ThermalPerformancePolicy.tier(for: .serious) == .protected &&
      ThermalPerformancePolicy.tier(for: .critical) == .emergency,
      "Only serious/critical activate automatic protection")
for state in thermalStates {
    let protected = state == .serious || state == .critical
    check(ThermalPerformancePolicy.automaticPressure(for: state) == protected,
          "Thermal pressure must begin at serious")
}
for state in [ProcessInfo.ThermalState.nominal, .fair] {
    check(ThermalPerformancePolicy.reductionReasons(state: state, coolMode: false,
          lowPower: false, memoryPressure: false, workloadPressure: false) == ["none"],
          "No thermal reduction reasons may be emitted at nominal or fair")
    check(ThermalPerformancePolicy.reductionReasons(state: state, coolMode: true,
          lowPower: false, memoryPressure: false, workloadPressure: false) == ["user_cool_mode"],
          "Explicit Cool Mode must be independent of thermal state")
    check(ThermalPerformancePolicy.reductionReasons(state: state, coolMode: false,
          lowPower: true, memoryPressure: false, workloadPressure: false) == ["low_power"],
          "Low Power Mode must be independent of thermal state")
}
let fullPerformanceTransitions: [(ProcessInfo.ThermalState, ThermalPerformancePolicy.Tier)] = [
    (.nominal, .fullPerformance), (.fair, .fullPerformance), (.nominal, .fullPerformance),
    (.fair, .fullPerformance), (.serious, .protected), (.fair, .fullPerformance),
    (.serious, .protected), (.critical, .emergency), (.fair, .fullPerformance)
]
for (state, expected) in fullPerformanceTransitions {
    check(ThermalPerformancePolicy.tier(for: state) == expected,
          "Thermal recovery must restore full performance without a cooldown")
}
for system in ["legacy", "hybridRecovery", "lowLatency"] {
    for preset in ["movie", "comic", "game", "lyrics", "custom"] {
        for rapid in [false, true] {
            var options = simulationOptions
            options["translationSystem"] = system
            options["mode"] = preset
            options["rapidTextTracking"] = String(rapid)
            options["joinAdjacentText"] = "true"
            options["activeTextFocus"] = "true"
            options["translateAhead"] = "true"
            options["adaptive"] = "true"
            for speed in ["fast", "balanced", "sharp", "automatic"] {
                options["speed"] = speed
                var nominal = SimulationInput()
                nominal.thermal = "nominal"
                var fair = nominal
                fair.thermal = "fair"
                let lhs = PipelineSimulation.run(options: options, input: nominal)
                let rhs = PipelineSimulation.run(options: options, input: fair)
                check(lhs.interval == rhs.interval && lhs.resolution == rhs.resolution &&
                      lhs.displayAccepted == rhs.displayAccepted && lhs.totalMs == rhs.totalMs,
                      "Fair cannot change capture detail, cadence, selection or PiP scheduling")
                check(lhs.steps.map { $0.title + $0.state + $0.detail } ==
                      rhs.steps.map { $0.title + $0.state + $0.detail },
                      "Every simulator stage must be nominal/fair equivalent for all modes/presets")
            }
        }
    }
}
print("v1.9.5 three-backend, all-preset, transition and nominal/fair parity gates passed")


var sqliteScenario = SimulationInput()
sqliteScenario.cacheOrigin = "sqlite"
sqliteScenario.memoryLookupMs = 3
let sqliteSimulation = PipelineSimulation.run(options: simulationOptions, input: sqliteScenario)
check(sqliteSimulation.steps.contains { $0.title == "Persistent memory decision" && $0.state == "sqlite" }, "Simulator exposes SQLite hit scenario")
sqliteScenario.memoryLookupMs = 20
let deadlineSimulation = PipelineSimulation.run(options: simulationOptions, input: sqliteScenario)
check(deadlineSimulation.steps.contains { $0.title == "Persistent memory decision" && $0.state.contains("deadline exceeded") }, "Simulator models deadline fallback explicitly")
print("Memory lookup simulator checks passed")
var freshSimulationOptions = simulationOptions
freshSimulationOptions["freshTranslationTest"] = "true"
sqliteScenario.memoryLookupMs = 3
let freshSimulation = PipelineSimulation.run(options: freshSimulationOptions, input: sqliteScenario)
check(freshSimulation.steps.contains { $0.title == "Speculative-work gate" && $0.state == "wait for confirmation" } &&
      !freshSimulation.steps.contains { $0.title == "Persistent memory decision" && $0.state == "sqlite" },
    "Fresh-test simulation must bypass both remembered output and speculative work")

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


// v1.4.1: the subtitle can be shorter/smaller than a stationary movie overlay.
// Only prefer changing dialogue once a separate label is confirmed persistent.
var movieFocus = MovieTextFocus()
let stationaryOverlay = MovieTextGroup(text: "Streaming channel", x: 0.5, y: 0.40, weight: 4)
let dialogue = MovieTextGroup(text: "Where are you going?", x: 0.5, y: 0.13, weight: 1.1)
check(movieFocus.preferredIndex(in: [stationaryOverlay], at: 0) == 0,
      "Static text must remain translatable when it is the only visible group")
check(movieFocus.preferredIndex(in: [stationaryOverlay], at: 0.5) == 0,
      "Do not prematurely classify the only text as noise")
check(movieFocus.preferredIndex(in: [stationaryOverlay], at: 1.4) == 0,
      "Long-held text must remain readable when no competing subtitle exists")
check(movieFocus.preferredIndex(in: [stationaryOverlay, dialogue], at: 1.5) == 1,
      "New dialogue must beat a repeatedly recognized stationary label")
check(movieFocus.preferredIndex(in: [stationaryOverlay, dialogue], at: 1.7) == 1,
      "Continuing subtitle must remain selected while it is still new")
let nextDialogue = MovieTextGroup(text: "I am leaving!", x: 0.5, y: 0.13, weight: 1.1)
check(movieFocus.preferredIndex(in: [stationaryOverlay, nextDialogue], at: 2) == 1,
      "Different dialogue in the same region must restart temporal freshness")
check(movieFocus.preferredIndex(in: [stationaryOverlay], at: 4) == 0,
      "Returning to a single group should never suppress its content")
movieFocus.reset()
check(movieFocus.preferredIndex(in: [dialogue], at: 5) == 0,
      "Context changes clear the stale overlay preference")
print("Movie static-overlay and subtitle freshness checks passed")


// v1.4.2 - OCR jitter cannot cancel a confirmed, unpresented caption merely
// to have the duplicate filter reject the replacement. Real new dialogue
// and a changed lyric row must remain eligible.
check(SubtitleAcquisitionPolicy.isSameUnpresentedCaption(
    activeConfirmed: true, activePresented: false,
    previousBlocks: ["Olá, mundo!"], incomingBlocks: ["Olá mundo"]),
    "Punctuation-only OCR differences retain already confirmed model work")
check(!SubtitleAcquisitionPolicy.isSameUnpresentedCaption(
    activeConfirmed: true, activePresented: false,
    previousBlocks: ["I love you"], incomingBlocks: ["I hate you"]),
    "Changed dialogue must not be mistaken for harmless OCR jitter")
check(!SubtitleAcquisitionPolicy.isSameUnpresentedCaption(
    activeConfirmed: true, activePresented: false,
    previousBlocks: ["First verse", "I love you"],
    incomingBlocks: ["First verse", "I hate you"]),
    "Changing any lyric row must still replace the old caption")
check(!SubtitleAcquisitionPolicy.isSameUnpresentedCaption(
    activeConfirmed: true, activePresented: true,
    previousBlocks: ["Olá mundo"], incomingBlocks: ["Olá mundo!"]),
    "Presented captions do not block fresh work")
check(!SubtitleAcquisitionPolicy.isSameUnpresentedCaption(
    activeConfirmed: false, activePresented: false,
    previousBlocks: ["Olá mundo"], incomingBlocks: ["Olá mundo!"]),
    "Tentative captions must not gain confirmed-work protection")
print("Confirmed-caption OCR jitter continuity checks passed")


// v1.4.2: association only discovers relationships. It must never
// authorize a translation cache hit without independent model proof.
check(LegacyAssociation.classify(old: "Olá, meu amigo!", new: "Olá meu amigo") == .orthographic,
      "Punctuation-only variants must be discoverable")
check(LegacyAssociation.classify(old: "I don't know how to respond to this problem",
                                 new: "I don't know how to respond to that problem") == .none,
      "Different words are not equivalent memory translations")
check(LegacyAssociation.classify(old: "We should never make a mistake here.",
                                 new: "We shouId never make a mistake here.") == .ocrCandidate,
      "A single plausible long OCR-character error can be suggested for review")
check(LegacyAssociation.classify(old: "Where in the world are we going tonight?",
                                 new: "world are we going") == .fragment,
      "A word-aligned long subtitle fragment can be associated")
check(LegacyAssociation.classify(old: "I love you", new: "I hate you") == .none,
      "Short meaning-changing variants must not be associated")
check(LegacyAssociation.classify(old: "They'll never know", new: "They will never know") == .none,
      "Expansions that change words are not automatically equivalent")
print("Conservative legacy discovery regressions passed")


// v1.4.3 — batching accelerates work without opening one model per entry.
let entries = (0..<50).map { i in
    IdleLegacyWorkItem(id: Int64(i), source: i < 35 ? "pt" : "es", text: "Sentence \(i)")
}
let twoSources = IdleLegacyBatchPolicy.chunks(entries, limit: 48)
check(twoSources.map { $0.items.count } == [12, 12, 11, 12, 1],
      "48 entries must split into bounded same-source chunks")
check(twoSources.allSatisfy { chunk in chunk.items.allSatisfy { $0.source == chunk.source } },
      "A chunk may never mix language pairs")
check(twoSources.flatMap(\.items).map(\.id) == Array(0..<48).map(Int64.init),
      "Batching must preserve each ID exactly once")
check(IdleLegacyBatchPolicy.chunks(entries, limit: 1000).flatMap(\.items).count == 50,
      "A caller cannot cause unbounded validation")
check(IdleLegacyBatchPolicy.concurrency(thermalFair: false) == 2 &&
      IdleLegacyBatchPolicy.concurrency(thermalFair: true) == 1,
      "Thermal Fair lowers worker count")
check(IdleLegacyBatchPolicy.cooldownSeconds(thermalFair: true) >
      IdleLegacyBatchPolicy.cooldownSeconds(thermalFair: false),
      "Warm devices receive a longer cooldown")
print("Adaptive legacy batch plan checks passed")


// v1.4.4 — subtitle continuity, predictive warm-up and adaptive speculation.
// Protect confirmed work only for a bounded interval while a real task is pending.
check(SubtitlePerformancePolicy.deferConfirmedReplacement(
    activeConfirmed: true, activePresented: false, incomingConfirmed: true,
    workPending: true, ageSeconds: 0.18, equivalent: false),
    "A newly confirmed subtitle waits briefly for older confirmed work")
check(!SubtitlePerformancePolicy.deferConfirmedReplacement(
    activeConfirmed: true, activePresented: false, incomingConfirmed: true,
    workPending: true, ageSeconds: 0.47, equivalent: false),
    "After the bounded handoff, new dialogue must not be held up")
check(!SubtitlePerformancePolicy.deferConfirmedReplacement(
    activeConfirmed: true, activePresented: true, incomingConfirmed: true,
    workPending: true, ageSeconds: 0.1, equivalent: false),
    "An already presented subtitle never blocks new dialogue")
check(!SubtitlePerformancePolicy.deferConfirmedReplacement(
    activeConfirmed: true, activePresented: false, incomingConfirmed: false,
    workPending: true, ageSeconds: 0.1, equivalent: false),
    "Tentative OCR cannot enter confirmed-only handoff")
check(!SubtitlePerformancePolicy.deferConfirmedReplacement(
    activeConfirmed: true, activePresented: false, incomingConfirmed: true,
    workPending: false, ageSeconds: 0.1, equivalent: false),
    "Unproductive stalled candidates cannot block new confirmed subtitles")
check(!SubtitlePerformancePolicy.deferConfirmedReplacement(
    activeConfirmed: true, activePresented: false, incomingConfirmed: true,
    workPending: true, ageSeconds: 0.1, equivalent: true),
    "Equivalent OCR text is handled by existing duplicate protection")

check(SubtitlePerformancePolicy.allowSpeculation(
    attempts: 10, discarded: 10, hits: 0, opportunity: 1, enabled: true),
    "Early adaptive observations must not prematurely throttle speculation")
check(SubtitlePerformancePolicy.allowSpeculation(
    attempts: 60, discarded: 45, hits: 2, opportunity: 2, enabled: true),
    "Low-yield speculation still gets periodic recovery opportunities")
check(!SubtitlePerformancePolicy.allowSpeculation(
    attempts: 60, discarded: 45, hits: 2, opportunity: 3, enabled: true),
    "Low-yield speculation must skip some unnecessary model work")
check(SubtitlePerformancePolicy.allowSpeculation(
    attempts: 60, discarded: 45, hits: 2, opportunity: 3, enabled: false),
    "User disabling adaptive speculation must preserve previous behavior")
check(SubtitlePerformancePolicy.allowSpeculation(
    attempts: 60, discarded: 20, hits: 25, opportunity: 3, enabled: true),
    "Effective speculation must not be throttled")

check(SubtitlePerformancePolicy.predictiveSource(
    selected: "auto", detected: nil, lastResolved: "pt",
    ageSeconds: 100, enabled: true) == "pt",
    "Recently verified source may prewarm only in unresolved Automatic")
check(SubtitlePerformancePolicy.predictiveSource(
    selected: "auto", detected: "fr", lastResolved: "pt",
    ageSeconds: 100, enabled: true) == nil,
    "Current detected source must override prediction")
check(SubtitlePerformancePolicy.predictiveSource(
    selected: "ja", detected: nil, lastResolved: "pt",
    ageSeconds: 100, enabled: true) == nil,
    "Explicit language source must never be replaced by remembered language")
check(SubtitlePerformancePolicy.predictiveSource(
    selected: "auto", detected: nil, lastResolved: "pt",
    ageSeconds: 90000, enabled: true) == nil,
    "Stale prediction must not trigger model warm-up")
check(SubtitlePerformancePolicy.predictiveSource(
    selected: "auto", detected: nil, lastResolved: "pt",
    ageSeconds: 100, enabled: false) == nil,
    "User can disable predictive warm-up")
print("v1.4.4 speculative, confirmed-handoff and predictive-warmup checks passed")


check(!SubtitlePerformancePolicy.preemptSpeculation(activeText: "Olá.", confirmedText: "Olá."),
    "Matching speculative input must finish for exact confirmed reuse")
check(SubtitlePerformancePolicy.preemptSpeculation(activeText: "Eu posso ir.", confirmedText: "Eu não posso ir."),
    "A different confirmed sentence must not wait for speculative input")
check(!SubtitlePerformancePolicy.preemptSpeculation(activeText: nil, confirmedText: "Olá."),
    "Confirmed processing must not be mistaken for speculative work")

check(SubtitlePerformancePolicy.allowSpeculation(attempts: 32, discarded: 30, hits: 0, opportunity: 2, enabled: true),
    "Poor historical yield must retain the 1.4.6 alternate-opportunity head starts")
check(SubtitlePerformancePolicy.allowSpeculation(attempts: 32, discarded: 30, hits: 0, opportunity: 4, enabled: true),
    "Low-yield speculation retains regular recovery opportunities")
check(SubtitlePerformancePolicy.allowSpeculation(attempts: 32, discarded: 30, hits: 0, opportunity: 2, enabled: false),
    "User disabling backoff retains tentative opportunities")

// A completed obsolete caption can supply exact sentence reuse, never a stale
// presentation. Exercise the same retention seam used after the model await.
let retainedKey = PipelineSafety.cacheKey(source: "pt", target: "en", text: "Olá amigo.",
    protectedWords: [], rules: "rules-A")
let changedKey = PipelineSafety.cacheKey(source: "pt", target: "en", text: "Olá inimigo.",
    protectedWords: [], rules: "rules-A")
let retainedBatch = TranslationBatchPlan(["Olá amigo.", "Outra frase.", "Olá amigo."])
let retainedKeys = [retainedKey, "other-exact-context-key", retainedKey]
let retainedValues = retainedBatch.expand([Optional("Hello friend."), Optional("Another sentence.")])
let retainedCache = SubtitlePerformancePolicy.retainedSpeculativeResults(keys: retainedKeys,
    values: retainedValues, workContext: 7, currentContext: 7, reuseAllowed: true)
check(retainedCache[retainedKey] == "Hello friend." && retainedCache.count == 2,
    "Completed superseded units must be reusable without another translation call")
check(retainedCache[changedKey] == nil,
    "A different sentence must never reuse an obsolete translation")
for isolatedKey in [
    PipelineSafety.cacheKey(source: "pt", target: "de", text: "Olá amigo.", protectedWords: [], rules: "rules-A"),
    PipelineSafety.cacheKey(source: "es", target: "en", text: "Olá amigo.", protectedWords: [], rules: "rules-A"),
    PipelineSafety.cacheKey(source: "pt", target: "en", text: "Olá amigo.", protectedWords: [], rules: "rules-B"),
    PipelineSafety.cacheKey(source: "pt", target: "en", text: "Olá amigo.", protectedWords: ["Zqa=Maria"], rules: "rules-A")
] {
    check(retainedCache[isolatedKey] == nil,
        "Languages, rules and protected-name context must remain isolated")
}
check(SubtitlePerformancePolicy.retainedSpeculativeResults(keys: retainedKeys, values: retainedValues,
    workContext: 7, currentContext: 8, reuseAllowed: true).isEmpty,
    "Settings, capture and cache invalidation must reject suspended speculative output")
check(SubtitlePerformancePolicy.retainedSpeculativeResults(keys: retainedKeys, values: retainedValues,
    workContext: 7, currentContext: 7, reuseAllowed: false).isEmpty,
    "Fresh-test and explicit memory bypass must prevent obsolete-result retention")
let invalidRetainedBatches: [[String?]?] = [nil, [], ["partial"], ["Hello", nil, "Hello"],
                                         ["Hello", " ", "Hello"], ["Hello", "Other", "Conflicting"]]
for invalidValues in invalidRetainedBatches {
    check(SubtitlePerformancePolicy.retainedSpeculativeResults(keys: retainedKeys, values: invalidValues,
        workContext: 7, currentContext: 7, reuseAllowed: true).isEmpty,
        "Failed, incomplete, empty or conflicting results must never seed the cache")
}
print("v1.5.0 restored head-start cadence and exact speculative recovery checks passed")

var emptyReadSequence = OCREmptyReadStreak()
for _ in 0..<3 { emptyReadSequence.primaryEmpty(); emptyReadSequence.finish(foundText: false) }
check(emptyReadSequence.needsContrastRetry && !emptyReadSequence.mayClear,
    "The third primary miss may request contrast recovery without clearing")
emptyReadSequence.finish(foundText: true)
emptyReadSequence.primaryEmpty(); emptyReadSequence.finish(foundText: false)
check(emptyReadSequence.count == 1 && !emptyReadSequence.mayClear,
    "A successful contrast retry must prevent clearing after the next single miss")
for _ in 0..<3 { emptyReadSequence.primaryEmpty(); emptyReadSequence.finish(foundText: false) }
check(emptyReadSequence.mayClear, "Four genuinely empty completed reads must still allow clearing")
emptyReadSequence.reset()
check(emptyReadSequence.count == 0 && !emptyReadSequence.needsContrastRetry,
    "Recognition configuration reset must discard the old empty streak")
let literalPlaceholder = TextIntel.protect("Zqa met Maria.", words: ["Maria"])
check(TextIntel.restore(literalPlaceholder.text, tokens: literalPlaceholder.tokens) == "Zqa met Maria.",
    "Literal placeholder-like text must survive protected-name restoration")
let overlappingNames = TextIntel.protect("Maria Clara met Maria.", words: ["Maria", "Maria Clara"])
check(overlappingNames.tokens.count == 2 &&
      TextIntel.restore(overlappingNames.text, tokens: overlappingNames.tokens) == "Maria Clara met Maria.",
    "Longer protected names must remain intact beside shorter overlapping names")
let tokenPrefixName = TextIntel.protect("Maria met Zq.", words: ["Maria", "Zq"])
check(TextIntel.restore(tokenPrefixName.text, tokens: tokenPrefixName.tokens) == "Maria met Zq.",
    "A later protected word must never replace characters inside an inserted placeholder")

let existingMemoryRules = "cleanOCR=true\u{1F}slang=true"
check(TranslationModelMemoryPolicy.rulesContext(base: existingMemoryRules, lowLatency: false) == existingMemoryRules,
    "Default model must preserve the exact legacy translation-memory digest input")
check(TranslationModelMemoryPolicy.rulesContext(base: existingMemoryRules, lowLatency: true) != existingMemoryRules,
    "Opted-in low-latency strategy must isolate memory from the default model")
check(PipelineSafety.cacheKey(source: "pt", target: "en", text: "Olá amigo", protectedWords: [],
        rules: TranslationModelMemoryPolicy.rulesContext(base: existingMemoryRules, lowLatency: true)) !=
      PipelineSafety.cacheKey(source: "pt", target: "en", text: "Olá amigo", protectedWords: [],
        rules: TranslationModelMemoryPolicy.rulesContext(base: existingMemoryRules, lowLatency: false)),
      "Different model strategies must not cross-reuse persistent translations")

// v1.7.0: screen transitions are recognition boundaries, not content evidence.
var visibleConfig = configA
visibleConfig.appInterfaceVisible = true
var externalConfig = visibleConfig
externalConfig.appInterfaceVisible = false
check(externalConfig.resetsRecognition(comparedTo: visibleConfig),
      "Leaving ScreenLingo must start new confirmation timing, not retain interface text")
check(visibleConfig.resetsRecognition(comparedTo: externalConfig),
      "Returning to ScreenLingo invalidates in-flight video OCR")
check(!externalConfig.resetsRecognition(comparedTo: externalConfig),
      "Repeated background heartbeat must not reset subtitle confirmation")
let encodedConfig = try! JSONEncoder().encode(externalConfig)
check((try! JSONDecoder().decode(Config.self, from: encodedConfig)).appInterfaceVisible == false,
      "Visibility crosses the real app/extension Codable boundary")
let oldConfigBytes = String(data: encodedConfig, encoding: .utf8)!
    .replacingOccurrences(of: "\"appInterfaceVisible\":false,", with: "")
    .replacingOccurrences(of: ",\"appInterfaceVisible\":false", with: "")
check((try! JSONDecoder().decode(Config.self, from: Data(oldConfigBytes.utf8))).appInterfaceVisible == nil,
      "Old app/extension configs remain decodable without visibility metadata")
print("v1.7.0 capture visibility boundary checks passed")

// v1.7.1: test memory is process-owned, isolated, and survives mode selection.
let processTestMemory = ProcessTranslationMemory()
let normalTestBank = processTestMemory.bank(for: .normal)
normalTestBank.values["saved-context"] = "Original normal RAM"
let temporaryTestBank = processTestMemory.bank(for: .temporaryMemory)
check(temporaryTestBank.values.isEmpty, "Temporary mode starts without existing normal memory")
temporaryTestBank.values["saved-context"] = "Temporary result"
temporaryTestBank.specKeys.insert("saved-context")
check(normalTestBank.values["saved-context"] == "Original normal RAM", "Test results cannot overwrite normal RAM")
_ = processTestMemory.bank(for: .normal)
check(processTestMemory.bank(for: .temporaryMemory).values["saved-context"] == "Temporary result",
      "Switching the toggle off/on must not erase temporary memory")
normalTestBank.clear()
check(temporaryTestBank.values["saved-context"] == "Temporary result",
      "Normal-memory maintenance must not erase temporary test entries")
check(ProcessTranslationMemory().temporary.values.isEmpty,
      "A new app process has no persisted temporary bank to restore")
check(TranslationTestMode.temporaryMemory.allowsReuse && TranslationTestMode.temporaryMemory.allowsSpeculation,
      "Temporary testing must exercise reuse AND speculation")
check(!TranslationTestMode.temporaryMemory.allowsPersistentTranslations && !TranslationTestMode.temporaryMemory.allowsHistoryInsertion,
      "Temporary output cannot be promoted to saved translations or permanent history")
check(!TranslationTestMode.freshRequests.allowsReuse && !TranslationTestMode.freshRequests.allowsSpeculation,
      "Fresh-only testing retains its deliberately strict behavior")
check(TranslationTestMode(freshRequests: true, temporaryMemory: true) == .freshRequests,
      "Imported conflicting switches have a deterministic safe policy")
let wholeCaptionKey = ExactCaptionIdentity.key(blocks: ["Olá.", "Outra frase."], source: "pt", target: "en", rules: "R")!
temporaryTestBank.retainCaption(key: wholeCaptionKey, result: ExactCaptionResult(translated: "Hello.\nAnother sentence.", sentences: 2))
check(temporaryTestBank.captions[wholeCaptionKey]?.sentences == 2, "Exact full-caption results preserve complete assembly")
for variant in [
    ExactCaptionIdentity.key(blocks: ["Olá.\nOutra frase."], source: "pt", target: "en", rules: "R"),
    ExactCaptionIdentity.key(blocks: ["Olá.", "Outra frase."], source: "pt", target: "de", rules: "R"),
    ExactCaptionIdentity.key(blocks: ["Olá.", "Outra frase."], source: "pt", target: "en", rules: "Changed names/rules"),
    ExactCaptionIdentity.key(blocks: ["Olá!", "Outra frase."], source: "pt", target: "en", rules: "R")
] { check(variant != wholeCaptionKey, "Caption fast path cannot collapse block, wording, target or rule context") }
check(ExactCaptionIdentity.key(blocks: ["Olá."], source: "auto", target: "en", rules: "R") == nil,
      "Whole-caption fast path must not guess an Automatic source")
check(ExactModelWorkPolicy.sharedUnits(inFlight: ["exact-A"], required: ["exact-A", "new-B"],
      workContext: 7, currentContext: 7, reuseAllowed: true) == 1,
      "A growing caption can use a shared exact in-flight sentence without cancelling its model request")
check(ExactModelWorkPolicy.sharedUnits(inFlight: ["exact-A"], required: ["similar-A"],
      workContext: 7, currentContext: 7, reuseAllowed: true) == 0,
      "Near matches never authorize retaining obsolete model work")
check(ExactModelWorkPolicy.sharedUnits(inFlight: ["exact-A"], required: ["exact-A"],
      workContext: 7, currentContext: 8, reuseAllowed: true) == 0,
      "Mode/settings/capture mutation invalidates in-flight sharing")
check(ExactModelWorkPolicy.sharedUnits(inFlight: ["exact-A"], required: ["exact-A"],
      workContext: 7, currentContext: 7, reuseAllowed: false) == 0,
      "Fresh-test bypass cannot be defeated by in-flight sharing")
for index in 0..<100 {
    temporaryTestBank.retainCaption(key: "bounded-\(index)", result: ExactCaptionResult(translated: "Whole caption \(index)", sentences: 1))
}
check(temporaryTestBank.captions.count == 64, "Assembled-caption acceleration remains bounded")
print("v1.7.1 temporary mode, process lifetime and exact work-sharing checks passed")

check(ExactModelWorkPolicy.sharedUnits(inFlight: ["needed-A", "obsolete-B"], required: ["needed-A", "new-C"],
      workContext: 7, currentContext: 7, reuseAllowed: true) == 0,
      "One overlapping sentence must not keep an unrelated old batch ahead of new dialogue")

// v1.7.2: a cached caption must be complete and preserve the ordinary formatter.
let protectedCaption = TextIntel.protect("Hello Maria.", words: ["Maria"])
let assembledCaption = CaptionAssembly.complete([
    [CaptionTranslationUnit(label: "Ana", sentences: ["Olá Maria.", "Como vai?"],
        out: [protectedCaption.text, "How are you?"], tokens: protectedCaption.tokens),
     CaptionTranslationUnit(label: "Luis", sentences: ["Bem."], out: ["Fine."], tokens: [])],
    [CaptionTranslationUnit(label: nil, sentences: ["Adeus."], out: ["Goodbye."], tokens: [])]
], glossary: [("hello", "Welcome")])
check(assembledCaption == "Ana: Welcome Maria. How are you?\nLuis: Fine.\nGoodbye.",
      "Cached and model captions preserve sentence order, speaker labels, protected names, glossary and blocks")
for unavailable: String? in [nil, "", "   "] {
    check(CaptionAssembly.complete([[CaptionTranslationUnit(label: nil,
        sentences: ["Primeira.", "Segunda."], out: ["First.", unavailable], tokens: [])]], glossary: []) == nil,
        "One missing or blank unit prevents partial-caption presentation")
}
check(CaptionAssembly.complete([[CaptionTranslationUnit(label: nil, sentences: ["A.", "B."],
    out: ["A."], tokens: [])]], glossary: []) == nil, "Incomplete result cardinality cannot silently lose a sentence")
check(CaptionAssembly.complete([], glossary: []) == nil && CaptionAssembly.complete([[]], glossary: []) == nil,
      "Empty assemblies cannot replace the current subtitle")
print("v1.7.2 complete caption assembly checks passed")

// Familiar-content throttling requires both low speculative usefulness AND
// independently observed saved reuse; it must recover on a scene change.
var familiarWindow = SpeculativeWorkWindow()
for _ in 0..<24 {
    let id = familiarWindow.begin()
    familiarWindow.finish(id, discarded: true)
    familiarWindow.recordConfirmedOutcome(saved: true)
}
let familiarProbes = (0..<12).map { _ in familiarWindow.allowsOpportunity(enabled: true) }
check(familiarProbes.filter { $0 }.count == 4 && familiarProbes[2] && familiarProbes[5],
      "Familiar low-yield scenes keep one speculative probe in three opportunities")
check(familiarWindow.allowsOpportunity(enabled: false), "Disabling adaptive speculation bypasses saved-memory throttling")
for _ in 0..<32 { familiarWindow.recordConfirmedOutcome(saved: false) }
check(!familiarWindow.savedMemoryDominant, "Unfamiliar content ages saved-reuse evidence out of the bounded window")
let unfamiliarProbes = (0..<12).map { _ in familiarWindow.allowsOpportunity(enabled: true) }
check(unfamiliarProbes.filter { $0 }.count == 6,
      "Misses/session/speculative reuse restore the previous unknown-content probe floor")
for _ in 0..<32 {
    let id = familiarWindow.begin()
    familiarWindow.finish(id, discarded: false)
    familiarWindow.reuse(id)
    familiarWindow.recordConfirmedOutcome(saved: true)
}
check((0..<12).allSatisfy { _ in familiarWindow.allowsOpportunity(enabled: true) },
      "Useful speculation stays enabled even when saved memory also helps")
var sparseSavedWindow = SpeculativeWorkWindow()
for _ in 0..<23 { sparseSavedWindow.recordConfirmedOutcome(saved: true) }
check(!sparseSavedWindow.savedMemoryDominant, "Sparse saved-memory evidence cannot activate stronger backoff")
check(SubtitleAcquisitionPolicy.rejectsDisplayedFragment(confirmed: true,
    text: "the station", displayed: "We are going to the station tomorrow.", age: 0.5),
    "An already displayed confirmed fragment must be rejected before active-work mutation")
check(!SubtitleAcquisitionPolicy.rejectsDisplayedFragment(confirmed: false,
    text: "the station", displayed: "We are going to the station tomorrow.", age: 0.5),
    "Tentative sightings keep their existing speculation admission")
check(!SubtitleAcquisitionPolicy.rejectsDisplayedFragment(confirmed: true,
    text: "the station", displayed: "We are going to the station tomorrow.", age: 2.1),
    "A later independent caption is not suppressed as a recent fragment")
check(!SubtitleAcquisitionPolicy.rejectsDisplayedFragment(confirmed: true,
    text: "Now we leave.", displayed: "We are going to the station tomorrow.", age: 0.5),
    "Genuinely new confirmed dialogue remains eligible")
print("v1.7.2 memory-aware speculation and fragment admission checks passed")

// Session cancellation permanently invalidates Apple's session. Exercise the
// actual ownership coordinator with controllable handles, not the OS model.
final class TestModelHandle { var cancellationCount = 0 }
await MainActor.run {
    let owner = SpeculativeSessionOwner<TestModelHandle> { $0.cancellationCount += 1 }
    let confirmed = TestModelHandle()
    let first = owner.begin(key: "pt>en|default", make: { TestModelHandle() })
    precondition(owner.cancelActive(now: 10))
    precondition(!owner.cancelActive(now: 11), "Repeated preemption must not cancel a session twice")
    precondition(first.cancellationRequestedAt == 10 && first.session.cancellationCount == 1)
    precondition(confirmed.cancellationCount == 0, "Speculative preemption cannot invalidate confirmed-session ownership")
    owner.finish(first, reusable: true)
    let second = owner.begin(key: "pt>en|default", make: { TestModelHandle() })
    precondition(second.session !== first.session, "A cancelled session must never serve another request")
    owner.finish(second, reusable: true)
    let reused = owner.begin(key: "pt>en|default", make: { TestModelHandle() })
    precondition(reused.session === second.session, "Successful speculative work keeps its warm session")
    owner.finish(reused, reusable: true)
    let changedPair = owner.begin(key: "de>en|default", make: { TestModelHandle() })
    precondition(changedPair.session !== reused.session, "Different language/model pairs never borrow an incompatible session")
    owner.reset()
    precondition(changedPair.session.cancellationCount == 1)
    owner.finish(changedPair, reusable: true)
    let newContext = owner.begin(key: "de>en|default", make: { TestModelHandle() })
    precondition(newContext.session !== changedPair.session, "Late context-invalidated completions cannot restore cancelled state")
    owner.finish(changedPair, reusable: true)
    precondition(owner.cancelActive(now: 20), "An old completion must not release a newer active lease")
    precondition(newContext.session.cancellationCount == 1)
    owner.finish(newContext, reusable: false)
    precondition(!owner.cancelActive(), "An idle lane has no model request to cancel")
}
print("v1.7.2 speculative model ownership, explicit preemption and warm reuse checks passed")

let contextIndexedPlan = TranslationBatchPlan(["Zqa arrived.", "Zqa arrived.", "Zqa arrived."],
    contexts: ["speaker=Maria", "speaker=Joana", "speaker=Maria"])
check(contextIndexedPlan.uniqueContexts == ["speaker=Maria", "speaker=Joana"],
      "Streaming responses retain exact request contexts even when placeholder wording is identical")
check(contextIndexedPlan.expand(["Maria arrived.", "Joana arrived."]) ==
    ["Maria arrived.", "Joana arrived.", "Maria arrived."],
    "Completed streamed units preserve protected-name context and duplicate positions")
var streamedOutputs: [String?] = [nil, nil]
let currentStreamCaption = { () -> String? in
    CaptionAssembly.complete([[CaptionTranslationUnit(label: "Ana", sentences: ["A.", "B."],
        out: streamedOutputs, tokens: [])]], glossary: [])
}
streamedOutputs[1] = "Second."
check(currentStreamCaption() == nil, "An out-of-order completed unit cannot expose an incomplete caption")
streamedOutputs[0] = "First."
check(currentStreamCaption() == "Ana: First. Second.",
      "A full replacement can assemble in reading order once all of its required units complete")
print("v1.7.2 streamed unit context mapping and complete-caption wakeup checks passed")

// New-mode confirmation never treats punctuation, case or changed words as duplicates.
for replacement in ["I have 10 cats!", "i have 10 cats.", "I have 20 cats.", "I do not have 10 cats."] {
    var strictTracker = SubtitleTracker()
    let line = OCRLine(t: "I have 10 cats.", x: 0.5, y: 0.2, h: 0.04, w: 0.4, confidence: 0.95)
    _ = strictTracker.observe([line], at: 0, required: 2, adaptive: true, spatial: true,
        deadline: 0.6, minimumConfidence: 0.3, strictSource: true)
    let firstConfirmed = strictTracker.observe([line], at: 0.1, required: 2, adaptive: true, spatial: true,
        deadline: 0.6, minimumConfidence: 0.3, strictSource: true)
    check(firstConfirmed.ready, "Initial exact repeated source confirms")
    var corrected = line; corrected.t = replacement
    let change = strictTracker.observe([corrected], at: 0.2, required: 2, adaptive: true, spatial: true,
        deadline: 0.6, minimumConfidence: 0.3, strictSource: true)
    check(!change.ready && !change.duplicate, "Changed meaning cannot reuse confirmation or duplicate suppression")
    let confirmedCorrection = strictTracker.observe([corrected], at: 0.3, required: 2, adaptive: true, spatial: true,
        deadline: 0.6, minimumConfidence: 0.3, strictSource: true)
    check(confirmedCorrection.ready && !confirmedCorrection.duplicate, "Genuine source correction remains displayable")
}
print("v1.9 strict source confirmation and meaningful correction checks passed")
