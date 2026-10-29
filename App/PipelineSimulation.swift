import Foundation
import NaturalLanguage

struct SimulationInput: Equatable {
    var text = "Olá meu amigo,\ncomo você está hoje?"
    var confidence = 0.95
    var height = 0.04
    var y = 0.2
    var motion = 2.0
    var ocrMs = 104.65
    var translationMs = 148.94
    var queueMs = 205.43
    var transferMs = 3.03
    var renderMs = 1.64
    var cacheOrigin = "fresh"
    var memoryLookupMs = 3.0
    var thermal = "nominal"
    var lowPower = false
    var emptyReads = 0
    var unchangedSeconds = 0.0
    var duplicateCopies = false
    var superseded = false
    var paused = false
    var frozen = false
    var packReady = true
    var pairSupported = true
    var rotationSettled = true
    var rotationProbes = 0
    var rotationVote = 0.0
    var priorSource = ""
    var priorText = ""
    var baseline = "16:11 diagnostic stage averages · assumptions for simulation"
}
struct SimulationStep: Identifiable {
    let id: Int
    let title: String
    let lane: String
    let state: String
    let detail: String
    let settings: [String]
    let start: Double
    let duration: Double
}
struct SimulationLane: Identifiable {
    let id: String
    let start: Double
    let end: Double
    let role: String
}
struct SimulationResult {
    var steps: [SimulationStep] = []
    var lanes: [SimulationLane] = []
    var totalMs = 0.0
    var output = ""
    var source = ""
    var resolution = 1400.0
    var interval = 0.22
    var confidence = 0.0
    var displayAccepted = false
}

/// Pure decision simulation. Durations and recognition quality are input assumptions, never predictions of device speed or correctness.
enum PipelineSimulation {
    static let optionGroups: [(String, [String])] = [
        ("Capture & recognition", ["mode","area","customY0","customY1","speed","frameRot","continuousRotation","stability","minTextH","boost","skipUnchanged","ocrConfidence","ocrCorrection","idleBackoff","adaptiveOCR","adaptiveConfirmation","subtitleTracking","confirmationDeadline"]),
        ("Language & understanding", ["source","target","langLock","contextualLanguage","languageRecovery","cleanOCR","slang","speakerDetect","neverTranslate","sourceFixes","glossary","dropNoise","ignoreList","deduplicateCopies"]),
        ("Translation & memory", ["translateAhead","selectiveSpeculation","adaptiveSpeculation","speculationConfidence","keepWarm","predictiveWarmup","remember","memoryRAMCapacity","memorySoftLimit","freshTranslationTest","temporaryMemoryTest","privateSession"]),
        ("Scheduling & PiP", ["steadyCaptions","protectConfirmedPresentation","displayPolicy","minDisplay","autoClear","clearHold","winSize","theme","textSize","pipFont","showOriginal","highlightNames","pipWeight","pipAlignment","pipLineSpacing","pipPadding","originalFraction","pipScale","speakerAccent","heartbeatInterval","autoOpenPiP"]),
        ("Power, feedback & retention", ["adaptive","coolMode","smartCool","keepAwake","idleMinutes","sessionLimit","saveHistory","historyCapacity","historyRetentionDays","haptics","hapticStrength","speak","speechRate","interruptSpeech","autoCopy","autoCopyFormat","diagnosticsEnabled","detailedCollection","persistDiagnosticSessions","diagSamples","diagIncludeText","showSessionSpeakers"])
    ]
    static func effect(for key: String) -> String {
        for (group, keys) in optionGroups where keys.contains(key) { return group }
        return "Interface/workspace preference · no live OCR/model decision; retained in the settings snapshot"
    }
    static func bool(_ options: [String:String], _ key: String, _ fallback: Bool = false) -> Bool {
        guard let value = options[key] else { return fallback }
        return value == "true" || value == "1"
    }
    static func number(_ options: [String:String], _ key: String, _ fallback: Double) -> Double {
        guard let n = Double(options[key] ?? ""), n.isFinite else { return fallback }
        return n
    }
    static func run(options o: [String:String], input s: SimulationInput) -> SimulationResult {
        var r = SimulationResult()
        func b(_ key: String, _ fallback: Bool = false) -> Bool { bool(o,key,fallback) }
        func n(_ key: String, _ fallback: Double) -> Double { number(o,key,fallback) }
        func add(_ title: String, _ lane: String, _ state: String, _ detail: String, _ keys: [String], _ start: Double = 0, _ duration: Double = 0) {
            r.steps.append(SimulationStep(id: r.steps.count, title: title, lane: lane, state: state, detail: detail, settings: keys, start: start, duration: duration))
        }
        let speed = o["speed"] ?? "balanced"
        var edge = speed == "fast" ? 1000.0 : (speed == "sharp" ? 2000 : 1400)
        var baseInterval = speed == "fast" ? 0.12 : (speed == "sharp" ? 0.4 : 0.22)
        if b("adaptive",true) {
            if s.thermal == "serious" { edge *= 0.75; baseInterval *= 1.5 }
            if s.thermal == "critical" { edge *= 0.55; baseInterval *= 2.5 }
            if s.lowPower { baseInterval *= 1.5 }
        }
        let cool = b("coolMode"), smartCool = cool && b("smartCool",true)
        if cool && !smartCool { baseInterval = max(0.45, baseInterval*2) }
        let feedback = RecognitionFeedback(confidence: s.confidence, textHeight: s.height, processingMs: s.ocrMs, failures: s.emptyReads, unchangedSeconds: s.unchangedSeconds, motion: s.motion)
        let plan = AdaptiveRecognition.plan(baseEdge: edge, interval: baseInterval,
            enabled: speed == "automatic" || (speed == "balanced" && b("adaptiveOCR",true)), cool: smartCool,
            pressure: b("adaptive",true) && s.thermal != "nominal", feedback: feedback,
            ceiling: (s.thermal == "serious" || s.thermal == "critical") ? edge : 2400)
        r.resolution = plan.edge; r.interval = plan.interval
        add("Video frame", "ReplayKit extension", s.paused ? "paused" : "received", "Virtual frame: sample text and normalized boxes. No screen capture occurs in this simulator.", ["mode","idleMinutes","sessionLimit"])
        if s.paused { add("Capture paused", "ReplayKit extension", "stop", "No OCR, translation or PiP replacement is scheduled.", []); return r }
        var rotationBudget = RotationBudget()
        for _ in 0..<max(0,min(4,s.rotationProbes)) { _ = rotationBudget.next() }
        let probe = (o["frameRot"] ?? "auto") == "auto" && (!s.rotationSettled || b("continuousRotation")) && RotationBudget.sufficientEvidence(vote:s.rotationVote,samples:3)
        let rotationState = probe ? rotationBudget.next().map { "probe \($0*90)°" } ?? "probe budget exhausted" : ((o["frameRot"] ?? "auto") == "auto" ? "holding device orientation" : (o["frameRot"] ?? "0") + "°")
        add("Orientation", "ReplayKit extension", rotationState, b("continuousRotation") ? "Device orientation plus optional clockwise rotation. Continuous rechecking is enabled." : "Device orientation plus a bounded search. A settled orientation is held until orientation/settings change.", ["frameRot","continuousRotation"])
        let area = o["area"] ?? "smart"
        var range: ClosedRange<Double> = 0...1
        if area == "custom" { range = ExportFormat.normalizedArea(n("customY0",0),n("customY1",0.5)) }
        else if area == "bottom" { range = 0...0.33 }
        else if area == "top" { range = 0.5...1 }
        else if area == "middle" { range = 0.3...0.7 }
        let rawRows = s.text.components(separatedBy: "\n").filter { !$0.isEmpty }
        var lines = rawRows.enumerated().map { index, text in
            OCRLine(t: text, x: 0.5, y: s.y + Double(rawRows.count-1-index)*s.height*1.3, h: s.height, w: 0.55, confidence: s.confidence)
        }
        if s.duplicateCopies { lines += lines.map { line in var copy = line; copy.y = min(0.9,line.y+0.4); return copy } }
        lines = lines.filter { range.contains($0.y) && $0.h >= n("minTextH",0) }
        add("Crop & workload plan", "ReplayKit extension", "\(Int(plan.edge)) px · \(Int(plan.interval*1000)) ms", "\(plan.reason). Crop y=\(String(format:"%.2f",range.lowerBound))…\(String(format:"%.2f",range.upperBound)); \(lines.count) boxes retained. Resolution is a ceiling; native image detail is not invented.", ["area","customY0","customY1","minTextH","speed","adaptiveOCR","adaptive","coolMode","smartCool","idleBackoff"])
        if b("skipUnchanged",true), s.unchangedSeconds > 0, s.motion <= 1.5 {
            add("Unchanged-frame gate", "ReplayKit extension", "defer", "A matching signature can defer a pass up to \(SubtitleAcquisitionPolicy.maximumUnchangedDelay(movie: (o["mode"] ?? "movie") == "movie")) seconds; pending confirmation still gets fresh reads. This run shows the next eligible pass.", ["skipUnchanged"])
        }
        let readMs = max(0,s.ocrMs)
        let floor = max(0.1,min(0.95,n("ocrConfidence",0.3)))
        lines = lines.filter { ($0.confidence ?? 0) >= floor }
        add("Accurate OCR", "Vision", lines.isEmpty ? "no accepted text" : "\(Int(s.confidence*100))% assumed confidence", "Assumed pass cost \(Int(readMs)) ms; correction \(b("ocrCorrection",true) ? "on" : "off"); contrast policy \(o["boost"] ?? "1"). Real Vision output/accuracy cannot be inferred from a text-only simulation.", ["ocrCorrection","ocrConfidence","boost"],0,readMs)
        if lines.isEmpty { add("Recognition recovery", "ReplayKit extension", "retry later", "Empty/low-confidence reads request more detail when adaptive recognition is enabled. Contrast fallback can retry every third empty pass. Nothing is sent to the model.", ["boost","adaptiveOCR","idleBackoff"]); return r }
        var tracker = SubtitleTracker()
        let required = max(1, min(3,Int(n("stability",2))))
        let pendingInterval = SubtitlePerformancePolicy.confirmationInterval(
            planned: plan.interval * SubtitleAcquisitionPolicy.idleMultiplier(
                movie: (o["mode"] ?? "movie") == "movie", enabled: b("idleBackoff",true),
                secondsSinceText: s.unchangedSeconds),
            pending: true, movie: (o["mode"] ?? "movie") == "movie",
            pressure: cool || s.lowPower || s.thermal != "nominal", processingMs: readMs)
        let cadenceMs = max(pendingInterval*1000,readMs)
        var confirmationMs = 0.0, confirmed = false, reason = "fixed read count"
        for index in 0..<12 {
            let time = Double(index)*cadenceMs/1000
            if b("subtitleTracking",true) || b("adaptiveConfirmation") {
                let decision = tracker.observe(lines, at: time, required: required, adaptive: b("adaptiveConfirmation"), spatial: b("subtitleTracking",true), deadline: n("confirmationDeadline",0.6), minimumConfidence: floor)
                if decision.ready { confirmed = true; confirmationMs = time*1000; reason = decision.reason; break }
            } else if index+1 >= required { confirmed = true; confirmationMs = time*1000; break }
        }
        add("Candidate identity & confirmation", "ReplayKit extension", confirmed ? reason : "still uncertain", "\(required) configured reads; confidence-aware policy \(b("adaptiveConfirmation") ? "on" : "off"). Tracking checks content, position and lifetime. A changed candidate gets a new work identity.", ["stability","adaptiveConfirmation","confirmationDeadline","subtitleTracking"],readMs,confirmationMs)
        if !confirmed { return r }
        let delivery = max(0,s.transferMs)
        let confirmedAt = confirmationMs + readMs + delivery
        add("Local delivery & source filtering", "Main app", "accepted", "Localhost UDP; own-output filtering remains in the real pipeline. Noise/ignore rules apply to the sample; Movie selects dominant connected groups, while Game/Comic retain separate regions. Group ranking here is illustrative for the sample geometry.", ["mode","dropNoise","ignoreList","deduplicateCopies"],confirmationMs+readMs,delivery)
        var blocks = OCRGrouping.makeBlocks(lines, movie: (o["mode"] ?? "movie") == "movie")
        if b("deduplicateCopies",true) { var regions = SubtitleRegions(); blocks = regions.deduplicated(blocks) }
        var text = blocks.map { $0.map(\.t).joined(separator:" ") }.joined(separator:"\n")
        if b("cleanOCR",true) { text = TextIntel.cleanOCR(text) }
        for row in (o["sourceFixes"] ?? "").components(separatedBy:"\n") {
            let pair = row.split(separator:"=",maxSplits:1).map(String.init)
            if pair.count == 2 && !pair[0].isEmpty { text = text.replacingOccurrences(of:pair[0],with:pair[1],options:.caseInsensitive) }
        }
        let ignore = (o["ignoreList"] ?? "").components(separatedBy:"\n").filter { !$0.isEmpty }
        if (b("dropNoise",true) && TextIntel.isNoise(text)) || ignore.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            add("Content filter", "Main app", "stop", "Noise or an ignore rule rejected the sample; no translation is requested.", ["dropNoise","ignoreList"]); return r
        }
        let target = o["target"] ?? "en", selected = o["source"] ?? "auto"
        let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
        var hypotheses = Dictionary(uniqueKeysWithValues: recognizer.languageHypotheses(withMaximum:5).map { ($0.key.rawValue,$0.value) })
        if b("contextualLanguage",true), !s.priorSource.isEmpty, !s.priorText.isEmpty {
            var context = LanguageContext(); context.record(s.priorText,code:s.priorSource,confidence:0.95,now:0)
            if context.mayAssist(hypotheses,now:1) {
                let contextual = NLLanguageRecognizer(); contextual.processString(context.text + " " + text)
                let mixed = Dictionary(uniqueKeysWithValues: contextual.languageHypotheses(withMaximum:5).map { ($0.key.rawValue,$0.value) })
                if let best = mixed.max(by:{$0.value<$1.value}), best.value>=0.8, SourceLanguageRouter.sameLanguage(best.key,s.priorSource) { hypotheses = mixed }
            }
        }
        var router = SourceLanguageRouter()
        if !s.priorSource.isEmpty {
            for _ in 0..<4 { _ = router.resolve(hypotheses:[s.priorSource:0.95],target:target,letters:24,useLock:b("langLock",true),record:true) }
        }
        let choice = selected == "auto" ? router.resolve(hypotheses:hypotheses,target:target,letters:text.filter(\.isLetter).count,useLock:b("langLock",true),record:true) : SourceLanguageRouter.Choice(code:selected,origin:.selected)
        r.source = choice?.code ?? "undetermined"
        r.confidence = hypotheses.filter { SourceLanguageRouter.sameLanguage($0.key,r.source) }.values.max() ?? 0
        let evidence = hypotheses.sorted{$0.value>$1.value}.map { "\($0.key) \(Int($0.value*100))%" }.joined(separator:" · ")
        add("Language decision", "NaturalLanguage", "\(r.source) → \(target)", "Actual local text-classifier evidence on the sample: \(evidence). OCR recognition language stays separate. No target-language lock is permitted.", ["source","target","langLock","contextualLanguage","languageRecovery"])
        guard choice != nil else { return r }
        if SourceLanguageRouter.sameLanguage(r.source,target) { add("Already target language", "Main app", "stop", "No translation request is needed; the real app keeps its last translated output until normal clear/replacement.", ["source","target"]); return r }
        if b("slang",true) { text = TextIntel.expandSlang(text,lang:r.source) }
        let dialogue = b("speakerDetect",true) ? TextIntel.splitDialogue(text) : [(label:String?.none,text:text)]
        let names = dialogue.compactMap { $0.label }
        let words = (o["neverTranslate"] ?? "").components(separatedBy:CharacterSet(charactersIn:",\n")).filter{ !$0.isEmpty }
        let protected = TextIntel.protect(text,words:words)
        add("Understanding & grouping", "Main app", "\(blocks.count) regions · \(names.count) labels", "OCR clean-up/source fixes precede language handling. Slang, speaker splitting and protected tokens precede sentence batching. Sample after processing: \(protected.text)", ["cleanOCR","sourceFixes","slang","speakerDetect","neverTranslate","glossary"])
        let testMode = TranslationTestMode(freshRequests: b("freshTranslationTest"), temporaryMemory: b("temporaryMemoryTest"))
        let persistentOrigin = ["saved", "sqlite", "legacy"].contains(s.cacheOrigin)
        let origin = !testMode.allowsReuse || (persistentOrigin && (!testMode.allowsPersistentTranslations || !b("remember",true) || b("privateSession"))) ? "fresh" : s.cacheOrigin
        let speculate = testMode.allowsSpeculation && b("translateAhead",true) && !s.lowPower && s.thermal != "serious" && s.thermal != "critical" && (!cool || (smartCool && readMs<100 && s.thermal=="nominal"))
            && (!b("selectiveSpeculation",true) || SpeculationPolicy.credible(lines:lines,threshold:cool ? max(0.95,n("speculationConfidence",0.85)) : n("speculationConfidence",0.85)))
        add("Speculative-work gate", "Main app", speculate ? "credible early work" : "wait for confirmation", "Early work starts after the first OCR pass. Uncertain/near-duplicate candidates are declined, only the newest candidate is queued, and superseded results are never published. Model cancellation is cooperative. Adaptive throttling depends on runtime history and is not predicted here.", ["translateAhead","selectiveSpeculation","speculationConfidence","coolMode","smartCool"])
        add("Translation memory lookup", "Main app", origin, "Session, saved-memory and speculative hits are separate. Rule fingerprints, source/target and protected-token context namespace every entry. Memory capacity changes retention, not wording.", ["remember","memoryCapacity","privateSession","glossary"])
        let memoryCost = s.memoryLookupMs.isFinite ? min(50, max(0, s.memoryLookupMs)) : 3
        if ["sqlite", "legacy", "miss", "incompatible", "migration failed", "database unavailable"].contains(origin) {
            let memoryOutcome = memoryCost > 8 ? "deadline exceeded; fresh fallback" : origin
            add("Persistent memory decision", "Main app", memoryOutcome,
                "SIMULATED: exact-key compatibility only; an unavailable database, failed migration, incompatible entry or miss falls back to fresh translation. Timing is an editable assumption, not measured runtime evidence.", ["remember", "privateSession"], 0, min(8, memoryCost))
        }
        let isHit = origin == "session" || origin == "saved" || origin == "speculative" || (["sqlite", "legacy"].contains(origin) && memoryCost <= 8)
        if !isHit && (!s.packReady || !s.pairSupported) { add("Language readiness", "Translation framework", "blocked", s.pairSupported ? "Language packs need downloading. Speculative work never opens download UI." : "The chosen pair is unsupported; the simulator does not replace it with a different language.", ["source","target","keepWarm"]); return r }
        let modelMs = isHit ? 0 : max(0,s.translationMs)
        let queue = isHit ? 0 : max(0,s.queueMs)
        let modelStart = (speculate && !isHit ? readMs+delivery : confirmedAt)+queue
        let readyAt = max(confirmedAt,modelStart+modelMs)
        add("Queue & request coalescing", "Main app", "\(Int(queue)) ms assumed", "Confirmed work has priority. Exact sentence requests are coalesced while preserving block order and protected-name context; unchanged sentences can hit memory when one lyric row changes.", ["translateAhead","selectiveSpeculation"],modelStart-queue,queue)
        add("Translation model / cache response", "Translation framework", isHit ? "cache result" : "\(Int(modelMs)) ms assumed", "This screen does not call a translation model or download packs. It simulates response timing; translated wording and correctness are not predicted. Keep warm affects readiness in the real app, but its speed benefit is not invented here.", ["source","target","keepWarm","remember"],modelStart,modelMs)
        let current = CandidateValidity.isCurrent("sample-1",active:s.superseded ? "sample-2" : "sample-1",enabled:b("steadyCaptions",true))
        add("Generation & candidate validation", "Main app", current && !s.frozen ? "current" : "rejected", "Language/context changes, newer confirmed generations and frozen output still gate publication. A newer unconfirmed sighting cannot erase ongoing confirmed work; confirmed replacements remain subject to the bounded handoff.", ["steadyCaptions"],readyAt)
        if !current || s.frozen { return r }
        let hold = PresentationSchedule.remaining(policy:o["displayPolicy"] ?? "immediate",minimum:n("minDisplay",0),lastShown:0,now:readyAt/1000)*1000
        add("Optional readability hold", "Main app", "\(Int(hold)) ms", "Model processing overlaps optional readability time; only the remaining hold is applied once the result is ready.", ["displayPolicy","minDisplay"],readyAt,hold)
        let render = max(0,s.renderMs)
        let total = readyAt+hold+render
        r.totalMs = total; r.displayAccepted = true
        r.output = "Translation output (modeled)"
        add("PiP frame preparation & enqueue", "PiP", "accepted", "Caption font, alignment, original-text fraction, padding, scale, theme and speaker styling affect frame drawing. Cached immutable buffers service heartbeat samples. Physical display latency remains unmeasured.", ["winSize","theme","textSize","pipFont","showOriginal","highlightNames","pipWeight","pipAlignment","pipLineSpacing","pipPadding","originalFraction","pipScale","speakerAccent","heartbeatInterval","autoOpenPiP"],readyAt+hold,render)
        let persist = MemoryRetentionPolicy.mayPersist(privateSession:b("privateSession"),selectedSource:selected != "auto",confidence:r.confidence,confirmed:true) && b("remember",true) && testMode.allowsPersistentTranslations
        add("History, persistent memory & feedback", "Storage / feedback", persist ? "eligible" : "session only", "Persistent memory: \(persist ? "eligible confirmed entry" : "not promoted"). History: \(testMode.allowsHistoryInsertion && b("saveHistory",true) && !b("privateSession") ? "enabled" : "off/private"). Speech \(b("speak") ? "on" : "off"), haptics \(b("haptics") ? "on" : "off"), clipboard \(b("autoCopy") ? "on" : "off"). No side effect actually runs in this simulator.", ["privateSession","remember","saveHistory","historyCapacity","historyRetentionDays","haptics","hapticStrength","speak","speechRate","interruptSpeech","autoCopy","autoCopyFormat"],total)
        add("Clear, idle & diagnostic lifecycle", "Main app", b("diagnosticsEnabled",true) ? (b("detailedCollection") ? "detailed" : "simple") : "collection off", "Auto-clear \(b("autoClear",true) ? "on" : "off"), hold \(n("clearHold",1)) s. Idle pause/session limits and keep-awake remain independent. Simple records counters; detailed adds bounded events/graphs and subtitle traces. Recorder self-time excludes model work and async chart drawing.", ["autoClear","clearHold","idleMinutes","sessionLimit","keepAwake","diagnosticsEnabled","detailedCollection","diagSamples","diagIncludeText","showSessionSpeakers"],total)
        r.lanes = [SimulationLane(id:"Recognition & confirmation",start:0,end:confirmedAt,role:"Capture"),SimulationLane(id:"Queue",start:modelStart-queue,end:modelStart,role:"Main app"),SimulationLane(id:"Model or cache",start:modelStart,end:modelStart+modelMs,role:speculate ? "Speculative model" : "Confirmed model"),SimulationLane(id:"Readability hold",start:readyAt,end:readyAt+hold,role:"Main app"),SimulationLane(id:"Frame preparation",start:readyAt+hold,end:total,role:"PiP")]
        return r
    }
}

