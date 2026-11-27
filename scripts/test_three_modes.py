#!/usr/bin/env python3
"""Contract checks supplement the real asynchronous Swift coordinator tests."""
from pathlib import Path
import subprocess
import re
from sources import read_source
root = Path(__file__).resolve().parents[1]
base = 'e94542ce46cdb5b2426fdfd5dc258c932327762b'
def old(path, ref=base):
    return subprocess.check_output(['git', 'show', f'{ref}:{path}'], cwd=root, text=True)
def read(path):
    return (root / path).read_text()
def function(source, name):
    start = max(source.find('    private func ' + name + '('), source.find('\n    func ' + name + '(') + 1)
    assert start > 0 or source.startswith('    private func ' + name + '('), name
    # The function ends at its own closing brace, so moving neighbouring members to other files does not change the text.
    end = source.find('\n    }\n', start)
    text = source[start:end + 6 if end != -1 else len(source)]
    return text.replace('    private func ', '    func ', 1)  # access level may change when a member moves to another file
engine = read_source('TranslatorEngine')
# 2.2.3 (L2, owner-approved): `drain` and `process` may differ from e94542ce ONLY by these listed edits. Undoing exactly
# these edits must give back the original function, so nothing else in the Legacy drain/assembly algorithm changed.
L2_UNDO = {
    'drain': [
        ("        let epoch = drainEpoch\n        defer {\n            if epoch == drainEpoch {\n                busy = false\n                activeQueueOwner = .scheduling\n                drainTask = nil\n                replayDeferredConfirmedIfPossible()\n                startDrain()\n            }\n        }\n",
         "        defer {\n            busy = false\n            activeQueueOwner = .scheduling\n            drainTask = nil\n            replayDeferredConfirmedIfPossible()\n            startDrain()\n        }\n"),
        ("guard !Task.isCancelled, epoch == drainEpoch else { return }", "guard !Task.isCancelled else { return }"),
        ("                    if epoch == drainEpoch { currentSpeculativeText = nil }\n                    else if let at = detachedSpeculationAt {\n                        diag.noteModelState(\"legacy_detached_speculation_released\",\n                                            durationMs: max(0, Date().timeIntervalSince(at) * 1000))\n                    }\n",
         "                    currentSpeculativeText = nil\n"),
    ],
    'process': [
        # 2.5.2 (owner request): incremental translation recovery defaults to on. Only the default value changed.
        ('(display || flag("incrementalBatchRecovery", true))', '(display || flag("incrementalBatchRecovery", false))'),
        ("            // 2.2.3 (L2): a detached speculative call must not erase the newer confirmed call's in-flight set.\n            if modelUnitKeysInFlight == Set(items.map { $0.key }) {\n                modelUnitKeysInFlight.removeAll()\n                modelContextInFlight = nil\n            }\n",
         "            modelUnitKeysInFlight.removeAll()\n            modelContextInFlight = nil\n"),
        # 2.6.0 (measurement only): two counters for why a confirmed unit missed memory. Nothing is translated or reused differently.
        ("                        if display { noteMissKind(s) }\n", ""),
        ("                        if display { looseUnits.noteSeen(s) }\n", ""),
        # 2.6.1 (switch looseMemoryReuse): a loose memory hit is recorded like a normalized hit and counted. Nothing else in process changed.
        ('                            case "loose_hit":\n                                outcome = .normalizedHit\n                                if diag.enabled { diag.s.looseHits += 1 }\n', ""),
    ],
}
for name in ['process', 'drain', 'cachedCaption']:
    current = function(engine, name)
    for after, before in L2_UNDO.get(name, []):
        assert current.count(after) == 1, name + ': expected 2.2.3 L2 edit missing: ' + after[:60]
        current = current.replace(after, before)
    assert current.replace('SharedTranslationWork.unitKey', 'PipelineSafety.cacheKey') == function(old('App/TranslatorEngine.swift'), name), name + ' Legacy model drain/assembly algorithm changed beyond the listed 2.2.3 L2 edits'
# The only Legacy speculate() changes in v1.9.7 are reason-coded skips;
# confirmed drain, exact-cache safety and physical lease remain immutable.
legacy_speculate = function(engine, 'speculate')
for invariant in [
    'guard speculationAllowed else { return }',
    # 2.5.1 (changed with the code): one newest early translation may wait behind a running confirmed job.
    'guard queueBehind || (!busy && queued == nil) else',
    'EagerSpeculationPolicy.mayQueueBehindConfirmed(',
    'lastSpecText = joined',
    'specQueued = blocks',
    'startDrain()'
]:
    assert invariant in legacy_speculate, 'Missing essential Legacy speculation ownership: ' + invariant
assert 'SCREENLINGO_REFERENCE_LEGACY_ADMISSION' in engine
assert 'allowsCredibleOpportunity' in engine
assert 'legacyAdaptiveLowYieldSkips' in engine
# Recognition settings are no longer hard-coded to the built-in Movie category.
# Normalize only these intentional capability routing changes; all of the
# original Legacy extraction and active-text selection logic must stay intact.
reference_engine = old('App/TranslatorEngine.swift')
old_extract = function(reference_engine, 'extractTexts').replace('area.range(mode: mode)', 'area.range()')
# 2.2.1 (E13, owner decision D-5): a one-character CJK line may be translated from a confirmed packet. These two
# replacements are the only change to extractTexts; every other line must still equal the e94542ce original.
old_extract = old_extract.replace(
    '            if TextSim.norm(t).count < 2 { continue }\n            if flag("dropNoise", true) && TextIntel.isNoise(t) {',
    '            let singleCJK = allowsSingleCJK(t)\n            if TextSim.norm(t).count < 2 && !singleCJK { continue }\n            if flag("dropNoise", true) && TextIntel.isNoise(t, allowSingleCJK: singleCJK) {')
assert 'let singleCJK = allowsSingleCJK(t)' in old_extract, 'E13 normalization did not apply'
assert function(engine, 'extractTexts') == old_extract, 'Legacy extraction changed beyond preset-independent area routing'
old_select = function(reference_engine, 'selectBlocks').replace('if mode == .movie {', 'if flag("activeTextFocus", true) {')
assert function(engine, 'selectBlocks') == old_select, 'Legacy text selection changed beyond preset-independent focus routing'
assert 'if mode == .movie' not in engine, 'Recognition cannot be locked to the Movie category'
assert function(read_source('TranslationMemoryStore'), 'createSchema') == function(old('App/TranslationMemoryStore.swift'), 'createSchema')
assert function(read_source('TranslationMemoryStore'), 'upgradeSchemaV2') == function(old('App/TranslationMemoryStore.swift'), 'upgradeSchemaV2')
assert old('App/TranslationMemoryStore.swift', 'origin/codex/screenlingo-v1.8.0-performance') == old('App/TranslationMemoryStore.swift')
for token in ['com.diam0ndnex.screenlingo', 'com.diam0ndnex.screenlingo.broadcast']:
    assert token in read('project.yml')
assert 'ScreenLingo/TranslationMemory' in engine
assert 'base: snapshot, lowLatency: false' in engine
assert 'where output.strategies[i] == .appleDefault' in engine
assert 'knownDefault: true' in engine
assert 'activeTranslationSystem != .legacy && flag("subtitleTracking", true)' in engine
assert 'activeTranslationSystem == .legacy else' in engine
assert 'modeCoordinator.observe(caption' in engine
core = read_source('TranslationSystem')
# 2.5.0 (changed with the code): two modes. These three lines used to pin the three-case enum and the Hybrid branches.
assert core.count('case legacy, lowLatency') == 1 and 'hybridRecovery, lowLatency' not in core
assert '.hybridRecovery' not in core and '.hybridRecovery' not in engine and '.hybridRecovery' not in read_source('ModeTranslationService')
assert 'static let removedHybridRawValue = "hybridRecovery"' in core, 'the removed mode is known only by its saved name'
assert 'lowOrder.count > 256' in core
assert 'preferredStrategy: .highFidelity' not in read_source('ModeTranslationService')
assert '"26.6"' in read('.github/workflows/build.yml')
assert 'hybridPreview' not in engine
activity = engine[engine.index('    var translationActivity:'):engine.index('func refreshModePreparation')]
assert 'warmupStatus' not in activity, 'Readiness must not depend on an old mode\'s string label'
assert 'TranslationActivity.preparation' not in engine, 'Use observed preparation stages, not parsing status text'
assert 'modelReadiness.prepare(stage)' in engine
assert 'modelReadiness.finishExecution(success: true' in engine
assert 'modeService.activityChanged' in engine
assert 'backendActivity.liveReadiness(modelReadiness)' in engine
assert 'let activity = backendActivity.activity' in activity
assert 'heldByActualCall = true' in read_source('ModeTranslationService')
service = read_source('ModeTranslationService')
warm = service[service.index('    func warmInitially('):service.index('    func prepare(')]
assert 'InitialWarmupPolicy.strategies(for: system)' in warm
assert 'warmup: true' in warm
assert all(token not in warm for token in ['queueMemory', 'history.append', 'modeCoordinator', 'lowCache'])
assert 'warmup ? warmupLane' in service
assert 'preserveIdleSessions: true' in engine
assert 'lastModePreparationPair' in engine and 'lastModePreparationAt' in engine
# 2.5.0 (changed with the code): the Hybrid admission wiring is gone from the engine.
assert 'adaptiveHybrid' not in engine and 'noteOverlappingRecovery' not in engine and 'hybrid_' not in engine
assert 'lastModePreparationPair = ""' in function(engine, 'invalidatePending'), 'Capture changes must reset mode session readiness throttle'
assert 'lastModePreparationAt = .distantPast' in function(engine, 'invalidatePending')
assert '!backendActivity.executing' in engine, 'Avoid live inference contention during readiness checks'
assert 'pip.isShowingIdenticalFrame' in engine
assert 'pip_held_unchanged' in engine
assert 'installedCheckTTL: Double = 30' in service
assert 'backend_availability_ms' in service
assert 'backend_task_dispatch_ms' in service
assert 'hybrid_' not in service, '2.5.0: no Hybrid event is produced any more'
assert 'model_batch_completed", serviceMs' in service
# 2.5.0 (changed with the code): the coordinator serves Low Latency only; the Hybrid policies and events are deleted.
assert 'HybridAdmissionPolicy' not in core and 'HybridSchedulingPolicy' not in core and 'HybridBackendPin' not in core
assert '"hybrid_' not in core and 'SpeculationWaitPolicy' not in core
assert 'final class ModeCoordinator' in core and 'let strategy = RequestedTranslationStrategy.lowLatency' in core
assert 'self.committed != caption' in core
# Dropped later in 2.5.0: the archive no longer carries the removed mode's name or reason codes.
assert 'hybrid_hedged_recovery' not in read_source('DiagnosticArchive')
assert 'modeAvailabilityCheckMs' in read_source('Diagnostics')
assert 'exportModeEventWindow()' in read_source('Diagnostics')
assert 'backend_installed_cache_hit' in service
print('Legacy algorithm equivalence, installed schema/identity, no preview/refinement, bounded cache and model routing source contracts passed')
# ---- 2.4.0: latency rebuild. Source contracts only; nothing here is a device result or a speed claim. ----
work = read_source('SharedTranslationWork')
experimental = read_source('ExperimentalFeaturesView')
capture = read_source('SampleHandler')
diagnostics = read_source('Diagnostics')
archive = read_source('DiagnosticArchive')
shared = read_source('Shared')
# 2.5.0 (changed with the code): the Hybrid pin of 2.4.0 is removed with the mode. The deferral stays, Legacy only.
# 2.5.1 (changed with the code): the deferral defaults to OFF, so every first reading starts its early translation.
for setting, pinned, accessor, arm in (('deferArmedSpeculation', 'armedDeferPinnedKey', 'deferArmedSpeculation', 'armedDeferAB'),):
    assert f'= "{setting}"' in work and f'?? false, forKey: {pinned})' in work, setting + ' is pinned when a session starts'
    assert f'(UserDefaults.standard.object(forKey: {pinned}) as? Bool) ?? false' in work, setting + ' defaults to off'
    assert f'@AppStorage("{setting}") private var {setting} = false' in experimental and experimental.count(f'"{setting}"') >= 2, setting + ' has a toggle and resets'
    assert f'if TranslationHotPathAB.{accessor} {{ settings["{arm}"] = "on" }}' in diagnostics
    assert archive.count(f'"{arm}"') == 3, arm + ': export allowlist, cohort keys and the report column'
assert not (root / 'Shared/TranslationSystem+BackendPin.swift').exists() and not (root / 'Shared/TranslationSystem+HybridPolicy.swift').exists()
assert archive.count('"speculation_deferred_armed"') == 2, 'speculation_deferred_armed stays in the mode reasons and the whole-session reasons'
for reason in ('hybrid_pin_low_latency', 'hybrid_pin_default', 'hybrid_pin_wait_matching',
               'hybrid_model_switch_low_latency', 'hybrid_model_switch_default'):
    assert '"' + reason + '"' not in archive, reason + ' is gone from the archive with the mode'
# Pinned or not, Low Latency output still never enters the shared memory namespace.
assert 'where output.strategies[i] == .appleDefault' in engine
# Deferral: only for a first sighting whose pixel check is armed, only for Apple Default work, never for confirmed text.
assert 'var pixelArmed: Bool? = nil' in shared
assert 'if p.pixelArmed == true, TranslationHotPathAB.deferArmedSpeculation {' in function(engine, 'handleContent')
assert function(engine, 'handleContent').index('if p.pixelArmed == true') > function(engine, 'handleContent').index('if p.stable == false {\n            //'), 'deferral sits inside the first-sighting branch'
# 2.5.0 (changed with the code): the Low Latency path never defers (its early calls are short); only Legacy does.
assert 'deferredArmed' not in engine and 'let admitted = speculationAllowed &&' in engine
# Capture: the armed flag needs the unchanged pixel check, two reads, and a wait that ends with the OCR pass.
assert 'sendPixelArmed = pendingPixelRead != nil && max(1, cfg.stability ?? 2) == 2 &&\n            cfg.adaptiveConfirmation != true && confirmationWait <= lastOcrMs / 1000 + 0.05' in capture
assert 'if outcome != .pending { pendingPixelRead = nil }' in capture
confirm = read_source('PixelConfirmation')
for constant in ('static let inkContrast = 60', 'static let inkTolerance = 40', 'static let minimumInk = 12',
                 'return elapsed >= max(0.1, interval)'):
    assert constant in confirm, 'confirmation evidence must not be lowered: ' + constant
# OCR quality settings are untouched: accurate unless the Fast OCR experiment is on, correction as configured, same confidence gate.
assert 'r.recognitionLevel = fast ? .fast : .accurate' in capture
assert 'r.usesLanguageCorrection = fast ? false : (cfg.correction ?? true)' in capture
assert 'c.confidence >= Float(min(0.95, max(0.1, cfg.confidence ?? 0.3)))' in capture
assert 'fastOCR: flag("fastOCR", false)' in engine and '"fastOCR": false' in engine
# A thrown-away focused read forces the next frame to be read; it never skips a read.
assert capture.count('forceBroadRead = true') == 1 and 'guard ordinaryDue || mayProbeEarly || watchTriggered || forcedRead else' in capture
tracker = read('Shared/AdaptivePipeline.swift')
assert 'let normal = reads >= max(1, required) && (!adaptive || confidence >= max(minimumConfidence, 0.72))' in tracker
# The Apple call no longer starts from a new main-actor task; the lane is still held until the call returns.
assert 'let call = Task.detached(priority: .userInitiated)' in service and 'await call.value' in service
assert service.count('try await session.translations(from: requests)') == 1
assert 'return lane.invalidated ? nil : output' in service and 'lane.busy = false; lane.caption = nil' in service
# Diagnostics stay metadata-only and bounded.
assert '    var structuredEvents: [StructuredDiagnosticEvent] = []' in diagnostics and '@Published var structuredEvents' not in diagnostics
assert 'if modeTrace.count > 6000 + Self.ringTrimBlock {' in diagnostics and 'if structuredEvents.count > 6000 + Self.ringTrimBlock {' in diagnostics
assert 'static let ringTrimBlock = 256' in diagnostics, 'the export windows (5840, 5872) are smaller than 6000, so a block of 256 loses nothing'
for metric in ('legacyConfirmedOverlapMs', 'confirmationOCRReads', 'confirmationFrameWaitMs', 'rediscoveryLeadMs'):
    assert '"' + metric + '"' in diagnostics and '"' + metric + '"' in archive, metric
for field in ('pixelArmed', 'focusRediscoveries', 'confirmReads', 'confirmPixelRejections', 'confirmFrameWaitMs', 'rediscoveryLeadMs'):
    declaration = re.search(r'var ' + field + r': (Bool|Int|Double)\? = nil', shared)
    assert declaration, field + ' must be an optional number or flag (no text) so older builds ignore it'
assert 'privacy: "metadataOnly"' in diagnostics and 'textCapture: false' in diagnostics
assert 'static let version = "2.7.0"' in shared and 'static let build = 131' in shared
assert read('project.yml').count('"2.7.0"') == 3 and read('project.yml').count('"131"') == 3
assert '("2.4.0", "Build 117:' in shared and '("2.3.9", "Build 116:' in shared and '("2.5.0", "Build 118:' in shared
print('v2.4.0 source contracts passed: deferral (default off since 2.5.1, Legacy only), unchanged OCR and confirmation evidence, forced re-read, direct model call, metadata-only diagnostics, version')

# ---- 2.5.0: two modes, items A to F, quiet re-warm. Source contracts only; nothing here is a device result. ----
ui = read_source('TranslateScreen')
snapshot = read_source('TranslateSnapshot')
system = read('Shared/TranslationSystem.swift')
v250 = read('Shared/TranslationSystem+V250.swift')
focus = read('Shared/CaptionFocus.swift')
# Two modes in the UI; no Hybrid chip, note or search entry.
assert ui.count('modeChip(') == 3 and 'modeChip("Legacy"' in ui and 'modeChip("Low Latency"' in ui, 'two chips and their builder'
assert 'modeChip("Hybrid"' not in ui and 'Hybrid' not in read_source('SettingsSearchIndex') and 'Hybrid' not in read_source('SettingsCategories')
assert 'static let modes = ["legacy", "lowLatency"]' in read_source('TestRunViews')
# A saved Hybrid choice moves once to Low Latency with a notice; the old switch is ignored.
assert 'if value == removedHybridRawValue {' in system and 'defaults.set(TranslationSystem.lowLatency.rawValue, forKey: "translationSystem")' in system
assert 'defaults.set(true, forKey: hybridNoticePendingKey)' in system and 'hybridNoticeShownKey) as? Bool != true' in system
assert '"hybridTranslation") as? Bool == true' not in system
assert '.alert("Hybrid Recovery was removed", isPresented: hybridNotice)' in ui
assert 'TranslationSystem.migratedHybridReason' in archive, 'the migration reason code reaches the report'
# Low Latency without its pack asks; nothing switches the model by itself.
assert 'enum LowLatencyPackGate' in system and 'case .supported: return .askForPack(canDownload: true)' in system
assert 'case .installed, .unchecked: return .start' in system
assert '.alert(LowLatencyPackGate.title, isPresented: $askingForPack)' in ui
for button in ('Button("Download") { engine.download(snap.gateSource) }', 'Button("Use Legacy") {', 'Button("Cancel", role: .cancel) {}'):
    assert button in ui, button
assert 'intercept: packQuestion' in ui and 'if let intercept {' in read_source('StartButton')
assert 'hybrid_default_fallback' not in core and 'strategy: .appleDefault' not in core, 'the coordinator has no fallback to another model'
# Old Hybrid runs get no special support any more: no removed-mode code in the archive, report or comparison.
assert 'isRemovedMode' not in archive and 'removedMode' not in archive and '"hybridRecovery"' not in archive
assert 'self = Self(rawValue: raw) ?? .lowLatency' in system, 'an old record that names the removed mode still decodes'
# Every 2.5.0 item has a switch: default ON, pinned at session start, a toggle, a reset entry and a report label.
switches = re.findall(r'\("(\w+)", "(\w+Pinned)", "(\w+AB)"\)', work)
assert [s[0] for s in switches] == ['warmAtCaptureStart', 'reportStoredSessionTotals', 'confirmationReadReasons',
                                    'modelLengthBuckets', 'trustedCaptionBand', 'legacyHeadStart', 'quietRewarm'], switches
assert 'defaults.set((defaults.object(forKey: item.setting) as? Bool) ?? true, forKey: item.pinned)' in work
for setting, pinned, arm in switches:
    assert f'static var {setting}: Bool {{ pinned("{pinned}") }}' in work, setting
    # 2.5.3 (changed with the code): the Legacy head start defaults to off.
    default = 'false' if setting == 'legacyHeadStart' else 'true'
    assert f'@AppStorage("{setting}") private var {setting} = {default}' in experimental and experimental.count(f'"{setting}"') == 2, setting
    assert f'("{arm}", "' in work and archive.count(f'"{arm}"') >= 1, arm
assert experimental.count('UNVERIFIED effect') == 4 and 'CHANGES WHAT IS READ.' in experimental and 'CHANGES WHAT IS READ WHEN.' in experimental
# A: warm-up when capture starts, both modes, output never kept.
warm_file = read('App/Engine/TranslatorEngine+CaptureWarm.swift')
assert 'guard TranslationHotPathAB.warmAtCaptureStart, captureAlive,' in warm_file
assert engine.count('warmAtCaptureStart()') == 3, 'defined once, called at capture start and when the app leaves the screen'
assert 'repeatable: true' in warm_file and 'guard repeatable || warmupPolicy.claim(' in service
assert all(token not in warm_file for token in ['queueMemory', 'history', 'show(', 'ram.values'])
# B: a stored run keeps its whole-session totals when a report is made from it.
assert 'counters[reason] ?? (storedTotals ? counters["session_" + reason] : nil)' in archive
assert 'distributions[reason] ?? (storedTotals ? distributions["session_" + reason] : nil)' in archive
# C: fixed cause codes for an extra read; D: length buckets. Numbers only.
assert 'enum ExtraReadCause: Int' in v250 and v250.count('"extraRead') == 8
assert 'if cfg.extraReadReasons == true, candidateCount > 0 { extraReads[nextReadCause.rawValue] += 1 }' in capture
assert 'var extraReadReasons: [Int]? = nil' in shared and 'var headStartPrePassMs: Double? = nil' in shared
assert 'enum ModelLengthBucket: String, CaseIterable' in v250 and 'ModelLengthBucket.bucket(characters:' in engine
assert 'V250Names.counters.contains(name)' in diagnostics and 'V250Names.metrics.contains(name)' in diagnostics
assert '.union(V250Names.counters)' in archive and 'V250Names.metrics.contains(key)' in archive
# E: the trusted band never lowers what a read must show; it only decides whether the whole area is read again.
assert 'static let requiredAgreement = 2' in focus and 'guard line.confidence >= 0.85, line.height > 0 else { return false }' in focus
assert 'captionFocus.trusts(bounds: lineBounds, scan: focus)' in capture and 'if focusEnabled, !trustedChange,' in capture
assert 'trustedCaptionBand: (TranslationHotPathAB.trustedCaptionBand && activeTranslationSystem != .legacy) ? true : nil' in engine
# F: the fast pass can only start an early translation. It has its own identity and never goes through `admit`.
assert 'struct HeadStartGovernor' in v250 and 'static let requiredShare = 0.8' in v250 and 'static let minimumSamples = 6' in v250
prepass = capture[capture.index('// 2.5.0 (item F): Legacy only.'):capture.index('var lines = ocr(')]
assert 'admit(' not in prepass and 'stable: false' in prepass and 'tracker' not in prepass
assert 'packet.candidateID = "\\(captureID):hs:\\(headStartSent)"' in capture
assert 'created.recognitionLevel = .fast' in capture and capture.count('judgeHeadStart(confirmed: key)') == 2
assert 'legacyHeadStart: (TranslationHotPathAB.legacyHeadStart && activeTranslationSystem == .legacy &&' in engine
# Confirmation evidence and OCR settings of the normal read are the 2.4.0 ones (asserted above); version and changelog.
assert '("2.5.0", "Build 118:' in shared
print('v2.5.0 source contracts passed: two modes, migration notice, pack question, old reports readable, items A to F and quiet re-warm switchable (default on), metadata-only diagnostics, version')

# ---- 2.5.1: Legacy speed and a self-healing link. Source contracts only; nothing here is a device result. ----
v251 = read('Shared/TranslationSystem+V251.swift')
eager = read('App/Engine/TranslatorEngine+EagerSpeculation.swift')
loop = read_source('LoopbackServer')
# Eager early translation: a switch (default on, pinned, toggle, reset, report label), Legacy only, confirmed first.
assert '("legacyEagerSpeculation", "legacyEagerSpeculationPinned", "eagerSpeculationAB")' in v251
assert 'for item in v250Switches + v251Switches + v254Switches + v255Switches + v256Switches + v260Switches + v261Switches + v263Switches + v264Switches + v265Switches {' in work  # 2.6.4: changed with the code
assert '@AppStorage("legacyEagerSpeculation") private var legacyEagerSpeculation = true' in experimental and experimental.count('"legacyEagerSpeculation"') == 2
assert archive.count('"eagerSpeculationAB"') == 2 and 'v251ReportLabels' in archive
assert 'enabled && busy && confirmedRunning && !confirmedQueued' in v251, 'never queued while confirmed work waits'
assert 'if !confirmed { speculateBehindActiveCaption(p, texts: candidateTexts) }' in function(engine, 'handleContent')
for token in ('activeTranslationSystem == .legacy', 'p.stable == false', 'SpeculationPolicy.credible(', 'allowsCredibleOpportunity(',
              'TranslationHotPathAB.deferArmedSpeculation', 'speculate(texts)'):
    assert token in eager, token
assert 'activeCandidateID' not in eager and 'activeCandidateConfirmed' not in eager, 'it never replaces the active caption'
# Own lane on by default; the two changed defaults reach saved settings once.
assert '(UserDefaults.standard.object(forKey: legacyOwnLanePinnedKey) as? Bool) ?? true' in work
assert 'LegacyV251Defaults.applyOnce(defaults)' in work and 'static let changedKeys = ["deferArmedSpeculation", "legacyConfirmedOwnLane",\n                              "incrementalBatchRecovery", "subtitleAwareChangeDetection", "independentCaptureHeartbeat"]' in v251
# Head start judged by words; same correction as the normal read; the normal read is unchanged.
assert capture.count('HeadStartText.matches(') == 3 and 'waiting == key' not in capture.replace('was `waiting == key`', '')
assert 'created.usesLanguageCorrection = correction' in capture and '!headStartHeld(cfg)' in capture
# Pixel check: more lines, capped tolerance; evidence constants unchanged (asserted above).
assert 'static let maximumLines = 8' in confirm and 'max(1, min(maximumAllowance, original.inkCount / 50))' in confirm
assert 'static let maximumAllowance = 16' in confirm, '2.5.3: 2.5.0 tolerance for up to 4 lines'
# Link: a dead peer is dropped, the listener restarts after silence, the capture replaces a failed connection.
assert 'else { self.dropPeer(connection) }' in loop and 'func restart()' in loop
assert 'server.restart()' in engine
assert 'watchLink(c)' in capture and 'noteSendResult(failed: error != nil, on: connection)' in capture
assert 'guard let current = conn, current === old else { return }' in capture
assert '("2.5.1", "Build 119:' in shared
print('v2.5.1 source contracts passed: eager early translation (switch, Legacy only, confirmed first), own lane and no deferral by default, head start by words, 8-line pixel check, self-healing link, version')

# ---- 2.5.2: a running confirmed Legacy caption is finished instead of dropped. Source contracts only. ----
assert '("finishRunningCaption", "finishRunningCaptionPinned", "finishRunningAB")' in v251
assert 'enabled && busy && confirmedRunning && !captionQueued ? maximumHold : 0' in v251 and 'static let maximumHold = 1.0' in v251
handle = function(engine, 'handleContent')
assert 'ConfirmedHandoffPolicy.holdWhileOwnCallRuns(' in handle and 'enabled: TranslationHotPathAB.finishRunningCaption && activeTranslationSystem == .legacy' in handle
assert 'now.timeIntervalSince(receivedAt) < 1.2' in handle, 'a held caption is replayed within 1.2 s or dropped; the hold stays below that'
assert '@AppStorage("finishRunningCaption") private var finishRunningCaption = true' in experimental and experimental.count('"finishRunningCaption"') == 2
assert archive.count('"finishRunningAB"') == 2
assert '("2.5.2", "Build 120:' in shared
dup = read('Shared/OCRDuplicateFilter.swift')
assert 'enum OCRDuplicateFilter' in dup and 'abs(outer.y - inner.y) <= max(outer.h, inner.h) * 0.5' in dup and 'a.contains(b)' in dup
assert capture.count('if cfg.dropDuplicateLines == true { lines = OCRDuplicateFilter.filter(lines) }') == 2, 'normal and quick read'
assert 'var dropDuplicateLines: Bool? = nil' in shared and 'dropDuplicateLines: TranslationHotPathAB.ocrDuplicateFilter ? true : nil' in engine
assert 'OCRLine' not in v251.replace('OCRLine` ', ''), 'TranslationSystem parts are compiled without Shared.swift in CI test programs'
batches = read_source('TranslatorEngine')
assert '(!warmup && activeTranslationSystem == .legacy && TranslationHotPathAB.streamLegacyCalls)' in batches and 'if stream {' in batches
for setting, arm in (('ocrDuplicateFilter', 'duplicateLinesAB'), ('streamLegacyCalls', 'streamCallsAB')):
    default = 'false' if setting == 'streamLegacyCalls' else 'true'  # 2.5.3: streaming off by default
    assert f'@AppStorage("{setting}") private var {setting} = {default}' in experimental and experimental.count(f'"{setting}"') == 2, setting
    assert archive.count(f'"{arm}"') == 2 and f'("{setting}", "{setting}Pinned", "{arm}")' in v251, arm
print('v2.5.2 source contracts passed: finish the running caption (switch, Legacy only, own call only, hold below the replay limit), version')

# ---- 2.5.3: Legacy head start off by default (device data). ----
assert 'LegacyV251Defaults.pinHeadStartDefault(defaults)' in work and 'defaults.set(false, forKey: "legacyHeadStartPinned")' in v251
assert 'defaults.removeObject(forKey: "legacyHeadStart")' in v251 and 'static let v253AppliedKey = "legacyV253DefaultsApplied"' in v251
assert 'static let version = "2.7.0"' in shared and 'static let build = 131' in shared and '("2.5.3", "Build 121:' in shared
print('v2.5.3 source contracts passed: head start off by default, saved value reset once, version')

# ---- 2.5.4: pixel check for up to 24 lines, early translation judged on caption lines, report rows. ----
v254 = read('Shared/TranslationSystem+V254.swift')
assert 'static let maximumLines = 8' in confirm and 'static let manyLinesMaximum = 24' in confirm
assert 'allowMany ? manyLinesMaximum : maximumLines' in confirm and 'private static func matchesPerLine(' in confirm
assert 'if original.luma.count > maximumLines * perLine, original.luma.count % perLine == 0 {' in confirm
assert 'max(1, min(maximumAllowance, original.inkCount / 50))' in confirm, 'up to 8 lines the rule is unchanged'
assert 'PixelConfirmation.samplePoints(lines: boxes, allowMany: many)' in capture and 'let many = cfg.pixelManyLines == true' in capture
assert 'var pixelManyLines: Bool? = nil' in shared and 'pixelManyLines: TranslationHotPathAB.pixelManyLines ? true : nil' in engine
for setting, arm in (('pixelManyLines', 'manyLinesAB'), ('captionLineSpeculation', 'captionLinesAB')):
    assert f'@AppStorage("{setting}") private var {setting} = true' in experimental and experimental.count(f'"{setting}"') == 2, setting
    assert archive.count(f'"{arm}"') == 2 and f'("{setting}", "{setting}Pinned", "{arm}")' in v254, arm
assert 'v254ReportLabels' in archive and 'enum CaptionLineSelection' in v254
assert 'OCRLine' not in v254, 'TranslationSystem parts are compiled without Shared.swift in CI test programs'
intake = function(engine, 'handleContent')
assert 'let judgedLines = speculationJudgedLines(p, candidateTexts: candidateTexts)' in intake
assert intake.count('lines: judgedLines') == 2 and 'SpeculationPolicy.credible(lines: p.lines' not in intake
assert 'if p.pixelArmed == true, TranslationHotPathAB.deferArmedSpeculation {' in intake, 'deferral unchanged'
eager254 = read_source('TranslatorEngine')
assert 'func speculationJudgedLines(' in eager254 and 'guard TranslationHotPathAB.captionLineSpeculation, activeTranslationSystem == .legacy' in eager254
assert 'Why a first reading got no early translation (2.5.4' in archive
assert 'static let version = "2.7.0"' in shared and 'static let build = 131' in shared and '("2.5.4", "Build 122:' in shared
print('v2.5.4 source contracts passed: pixel check 24 lines (per-line tolerance), early translation judged on caption lines, switches, report rows, version')


# ---- 2.5.5: the text blocks of one subtitle are translated together (Legacy). ----
v255 = read('Shared/TranslationSystem+V255.swift')
assert '("captionJoin", "captionJoinPinned", "captionJoinAB")' in v255 and 'static var captionJoin: Bool' in v255
assert 'enum CaptionJoin' in v255 and 'static let maximumCharacters = 240' in v255
assert 'OCRLine' not in v255, 'TranslationSystem parts are compiled without Shared.swift in CI test programs'
join255 = read_source('TranslatorEngine')
assert 'func captionJoinedTexts(' in join255 and 'guard TranslationHotPathAB.captionJoin, activeTranslationSystem == .legacy, texts.count > 1 else { return texts }' in join255
intake255 = function(engine, 'handleContent')
assert 'let extractedTexts = extractTexts(p.lines, count: p.stable != false && !replayed)' in intake255
assert 'let candidateTexts = captionJoinedTexts(extractedTexts, count: p.stable != false && !replayed)' in intake255
assert function(engine, 'extractTexts') == old_extract, 'extractTexts stays the e94542ce original: the join happens after it'
assert '@AppStorage("captionJoin") private var captionJoin = true' in experimental and experimental.count('"captionJoin"') == 2
assert archive.count('"captionJoinAB"') == 2 and 'v255ReportLabels' in archive
assert 'captionMultiBlock' in archive and 'Text blocks per confirmed reading (2.5.5' in archive
assert 'static let version = "2.7.0"' in shared and 'static let build = 131' in shared and '("2.5.5", "Build 123:' in shared
print('v2.5.5 source contracts passed: subtitle text blocks joined, switch, counters, report rows, version')

# ---- 2.5.6: a growing subtitle settles before it is translated (Legacy). ----
v256 = read('Shared/TranslationSystem+V256.swift')
assert '("growthSettle", "growthSettlePinned", "growthSettleAB")' in v256 and 'struct CaptionGrowthTracker' in v256
assert 'OCRLine' not in v256 and 'TextSim' not in v256, 'TranslationSystem parts are compiled without Shared.swift in CI test programs'
assert 'static let maximumTotal = 0.9' in v256 and 'static let maximumQuiet = 0.6' in v256
growth256 = read_source('TranslatorEngine')
assert 'func holdGrowingCaption(' in growth256 and 'guard TranslationHotPathAB.growthSettle, activeTranslationSystem == .legacy else { return false }' in growth256
assert 'func isGrowingFirstReading(' in growth256 and 'func growthReset()' in growth256
intake256 = function(engine, 'handleContent')
assert 'if !replayed, p.stable != false,\n           holdGrowingCaption(p, text: candidateText, receivedAt: receivedAt, now: now) { return }' in intake256
assert 'if isGrowingFirstReading(candidateText, now: now) {' in intake256
assert intake256.index('holdGrowingCaption(') < intake256.index('let equivalentActiveCaption'), 'growth hold comes before supersession'
assert intake256.index('rejectsDisplayedFragment') < intake256.index('holdGrowingCaption('), 'admission rules run first'
assert 'growthReset()' in engine and 'var captionGrowth = CaptionGrowthTracker()' in read('App/TranslatorEngine.swift')
assert '@AppStorage("growthSettle") private var growthSettle = true' in experimental and experimental.count('"growthSettle"') == 2
assert archive.count('"growthSettleAB"') == 2 and 'v256ReportLabels' in archive and 'Growing subtitles (2.5.6' in archive
assert 'static let version = "2.7.0"' in shared and 'static let build = 131' in shared and '("2.5.6", "Build 124:' in shared
print('v2.5.6 source contracts passed: growing subtitles settle, switch, counters, report rows, version')

# ---- 2.6.0: translation recovers when it stops. ----
v260 = read('Shared/TranslationSystem+V260.swift')
assert '("stallWatchdog", "stallWatchdogPinned", "stallWatchdogAB")' in v260
assert 'struct ModelStallLimit' in v260 and 'enum ModelCallRace' in v260 and 'struct StallLadder' in v260 and 'final class ResumeGate' in v260
assert 'OCRLine' not in v260 and 'TextSim' not in v260, 'TranslationSystem parts are compiled without Shared.swift in CI test programs'
assert 'static let floorSeconds = 6.0' in v260 and 'static let ceilingSeconds = 30.0' in v260
stall260 = read_source('TranslatorEngine')
assert 'func stallWatchdogTick()' in stall260 and 'func abandonLane()' in stall260 and 'func dropModelSessions()' in stall260
assert 'guard TranslationHotPathAB.stallWatchdog, !paused, !frozen, captureAlive else {' in stall260
assert 'stallWatchdogTick()' in function(read_source('TranslatorEngine'), 'tick')
batches260 = read('App/Engine/TranslatorEngine+Batches.swift')
assert 'func performModelCall() async throws -> [String]? {' in batches260
assert 'try await ModelCallRace.run(limit: limit' in batches260 and 'if TranslationHotPathAB.stallWatchdog, !warmup {' in batches260
assert 'try await session.translations(from: reqs)' in batches260 and 'session.translate(batch: reqs)' in batches260
assert 'var modelStall = ModelStallLimit()' in read('App/TranslatorEngine.swift') and 'var stallLadder = StallLadder()' in read('App/TranslatorEngine.swift')
assert '@AppStorage("stallWatchdog") private var stallWatchdog = true' in experimental and experimental.count('"stallWatchdog"') == 2
assert archive.count('"stallWatchdogAB"') == 2 and 'v260ReportLabels' in archive and 'Stalls (2.6.0' in archive
assert 'static let version = "2.7.0"' in shared and 'static let build = 131' in shared and '("2.6.0", "Build 125:' in shared
print('v2.6.0 source contracts passed: stall watchdog, switch, counters, report rows, version')

# ---- 2.6.0: automatic quality signals and memory miss classification (measurement only). ----
q260 = read('Shared/TranslationSystem+Quality.swift')
assert 'enum CaptionFlag' in q260 and 'struct CaptionSignals' in q260 and 'OCRLine' not in q260 and 'TextSim' not in q260
m260 = read('Shared/TranslationSystem+MissClass.swift')
assert 'struct LooseUnitIndex' in m260 and 'OCRLine' not in m260 and 'TextSim' not in m260
assert 'noteShownSignals(text, result)' in function(engine, 'show') and 'func noteShownSignals(' in read_source('TranslatorEngine')
assert 'func noteMissKind(' in read_source('TranslatorEngine') and 'var looseUnits = LooseUnitIndex()' in read('App/TranslatorEngine.swift')
store260 = read('App/Diagnostics/FlaggedCaptionStore.swift')
assert 'static let maximumNotes = 200' in store260 and 'static let keepDays = 14.0' in store260
assert 'guard FlaggedCaptionStore.includeInReports, !flag("privateSession", false) else { return }' in read_source('TranslatorEngine')
assert '@AppStorage("flaggedCaptionText") private var flaggedCaptionText = true' in experimental
assert 'Flagged captions (text)' in archive and 'flagged: flagged)' in archive and 'FlaggedCaptionStore.includeInReports' in read_source('Diagnostics')
for name in ['qShown', 'qRewritten', 'missNearMiss', 'stallHangs']:
    assert '"%s"' % name in archive, name
print('v2.6.0 quality and miss-classification contracts passed')

# ---- 2.6.1: memory reuses saved translations that differ only in case, punctuation or spacing. ----
v261 = read('Shared/TranslationSystem+V261.swift')
assert '("looseMemoryReuse", "looseMemoryReusePinned", "looseMemoryReuseAB")' in v261 and 'enum LooseReuse' in v261
assert 'OCRLine' not in v261 and 'TextSim' not in v261 and 'static let minimumCharacters = 8' in v261
store261 = read_source('TranslationMemoryStore')
assert 'func ensureLooseKeyColumn() throws {' in store261 and 'ALTER TABLE memory_entries ADD COLUMN loose_key TEXT' in store261
assert 'CREATE INDEX IF NOT EXISTS memory_loose' in store261 and 'static let schemaVersion = 2' in store261, 'the schema version stays 2'
assert 'func lookupLoose(' in store261 and 'if looseReuse, normalizedResult.outcome == "miss" {' in store261
assert 'text(query, 2) == "ready", text(query, 3) == "persisted"' in store261 and 'return result(nil, "none", values.isEmpty ? "miss" : "conflict")' in store261
assert 'func backfillLooseKeys(limit: Int = 300) -> Int {' in store261 and 'try? execute("UPDATE memory_entries SET loose_key=? WHERE id=?"' in store261
assert 'setLooseReuse(TranslationHotPathAB.looseMemoryReuse)' in read_source('TranslatorEngine')
assert '@AppStorage("looseMemoryReuse") private var looseMemoryReuse = true' in experimental and experimental.count('"looseMemoryReuse"') == 2
assert archive.count('"looseMemoryReuseAB"') == 2 and 'v261ReportLabels' in archive and '"looseHits"' in archive
assert 'static let version = "2.7.0"' in shared and 'static let build = 131' in shared and '("2.6.1", "Build 126:' in shared
print('v2.6.1 source contracts passed: loose memory reuse, schema, switch, counters, version')

# ---- 2.6.1: guard for the growing-subtitle wait; abandon for a Low Latency call that ignores cancel. ----
assert 'enum SwitchGuard' in v261 and 'static var sessionOff: Set<String> = []' in v261
assert '!sessionOff.contains("growthSettle")' in read('Shared/TranslationSystem+V256.swift')
assert 'sessionOff.removeAll()' in read('Shared/SharedTranslationWork.swift')
assert 'func evaluateSwitchGuards()' in read_source('TranslatorEngine') and 'evaluateSwitchGuards()' in function(read_source('TranslatorEngine'), 'tick')
assert '"switch_guard_tripped"' in read('App/Diagnostics/Diagnostics+Setup.swift') and '"guardTrips"' in archive
lowlat261 = read('App/Engine/ModeTranslationService+Stall.swift')
assert 'static func awaitCall(' in lowlat261 and 'ModelCallRace.run(limit: abandonAfterSeconds)' in lowlat261 and 'guard TranslationHotPathAB.stallWatchdog else { return await call.value }' in lowlat261
assert 'ModeTranslationService.awaitCall(call)' in read('App/ModeTranslationService.swift')
print('v2.6.1 guard and Low Latency abandon contracts passed')

# ---- 2.6.1: the changelog is a Swift array literal; every entry but the last needs a trailing comma (CI build 126 failed on this). ----
_shared = read('Shared/Shared.swift').split('\n')
_start = next(i for i, l in enumerate(_shared) if 'static let changelog' in l)
_i = _start + 1
while not _shared[_i].strip().startswith(']'):
    _l = _shared[_i].rstrip()
    if _l.strip().startswith('("'):
        _last = _shared[_i + 1].strip().startswith(']')
        assert _l.endswith('"),') or (_last and _l.endswith('")')), f'changelog line {_i + 1} needs a trailing comma'
    _i += 1
print('v2.6.1 changelog syntax contract passed')

# ---- 2.6.2: automatic comparison with the session before it; CI runs the build once per push. ----
regression = read('App/Diagnostics/DiagnosticArchive+Regression.swift')
assert 'enum RunRegression' in regression and 'DiagnosticPerformanceComparison(baseline: before, current: after)' in regression
assert 'RunRegression.lines(sessions: selected, labels: labels)' in read('App/Diagnostics/DiagnosticArchive+CombinedReport.swift')
assert 'Tests/DiagnosticArchive' in read('scripts/test_diagnostics.sh') and 'RunRegression.compare' in read('Tests/DiagnosticArchive/main.swift')
build_yml = read('.github/workflows/build.yml')
assert 'pull_request' not in build_yml and 'python-checks:' in build_yml and 'ubuntu-latest' in build_yml
assert 'pull_request' not in read('.github/workflows/ui-screenshots.yml')
print('v2.6.2 contracts passed: regression comparison, CI layout')

# ---- 2.6.3: memory care (warm-up, quarantine) and slowest captions. ----
v263 = read('Shared/TranslationSystem+V263.swift')
assert '("memoryCare", "memoryCarePinned", "memoryCareAB")' in v263 and 'enum MemoryCare' in v263
care_store = read('App/Memory/TranslationMemoryStore+Care.swift')
assert 'func recentEntries(rules: String, target: String, limit: Int)' in care_store and 'func quarantine(requestedKey key: String) -> Int' in care_store
assert 'ALTER TABLE' not in care_store and 'user_version' not in care_store, 'memory care never changes the schema'
care = read('App/Engine/TranslatorEngine+MemoryCare.swift')
assert 'func warmRAMFromMemory()' in care and 'func quarantineDefectiveReuse(' in care
assert 'await self.warmRAMFromMemory()' in read('App/Engine/TranslatorEngine+Memory.swift') and 'await warmRAMFromMemory() /* 2.6.3 */' in read_source('TranslatorEngine')
assert 'quarantineDefectiveReuse(flags: flags, result: result)' in read('App/Engine/TranslatorEngine+Quality.swift')
assert 'diag.noteSlowCaption(latency.last)' in read_source('TranslatorEngine')
assert 'SlowCaptions.counterNames' in archive and '"memoryWarmed", "memoryQuarantined"' in archive
assert '@AppStorage("memoryCare") private var memoryCare = true' in experimental and experimental.count('"memoryCare"') == 2
assert 'static let version = "2.7.0"' in shared and 'static let build = 131' in shared and '("2.6.3", "Build 128:' in shared
print('v2.6.3 contracts passed: memory care, slowest captions, switch, version')

# ---- 2.6.4: display stability; preloaded RAM is not test memory. ----
v264 = read('Shared/TranslationSystem+V264.swift')
assert '("stableDisplay", "stableDisplayPinned", "stableDisplayAB")' in v264 and 'struct DisplayStability' in v264
engine264 = read_source('TranslatorEngine')
assert 'displayStability.decide(text, now: ProcessInfo.processInfo.systemUptime)' in engine264 and 'displayStability.shown(text' in engine264
assert 'displayStability.forget()' in read('App/Engine/TranslatorEngine+Quality.swift')
assert '"displayHeldVariant", "displayHeldFlip"' in archive and 'counters["memoryWarmed"] = ramWarmedEntries' in read('App/Diagnostics.swift')
assert '@AppStorage("stableDisplay") private var stableDisplay = true' in experimental and experimental.count('"stableDisplay"') == 2
assert 'static let version = "2.7.0"' in shared and 'static let build = 131' in shared and '("2.6.4", "Build 129:' in shared
print('v2.6.4 contracts passed: display stability, preloaded RAM, switch, version')

# ---- 2.6.5: lower and steadier latency (learned early start, sooner hang limit). ----
v265 = read('Shared/TranslationSystem+V265.swift')
assert '("learnedEarlyStart", "learnedEarlyStartPinned", "learnedEarlyStartAB")' in v265
assert '("quickHangLimit", "quickHangLimitPinned", "quickHangLimitAB")' in v265
assert 'struct SpecConfidenceLearner' in v265 and 'struct FirstReadingBook' in v265
assert 'static let quickFloorSeconds = 3.5' in read('Shared/TranslationSystem+V260.swift') and 'TranslationHotPathAB.quickHangLimit' in read('Shared/TranslationSystem+V260.swift')
learning = read('App/Engine/TranslatorEngine+EarlyStartLearning.swift')
assert 'func earlyStartConfidence(base: Double)' in learning and 'func noteFirstReading(' in learning and 'func noteConfirmedAgainstFirst(' in learning
intake265 = read_source('TranslatorEngine')
assert 'noteFirstReading(p, texts: candidateTexts)' in intake265 and 'noteConfirmedAgainstFirst(p, texts: candidateTexts)' in intake265
assert 'earlyStartConfidence(base: baseSpecConfidence)' in intake265 and 'earlyStartConfidence(base: base)' in intake265
assert 'var specLearner = SpecConfidenceLearner()' in intake265 and 'var firstReadings = FirstReadingBook()' in intake265
assert 'firstReadings.forget()' in read('App/Engine/TranslatorEngine+Quality.swift')
assert '"specLearnSamples", "specLearnMatches", "specLearnedMilli", "earlyStartByLearning"' in archive
assert 'counters["specLearnSamples"] = s.specLearnSamples' in read('App/Diagnostics.swift')
assert 'Early start learning (2.6.5' in read('App/Diagnostics/DiagnosticArchive+CombinedReport.swift')
assert '@AppStorage("learnedEarlyStart") private var learnedEarlyStart = true' in experimental and experimental.count('"learnedEarlyStart"') == 2
assert '@AppStorage("quickHangLimit") private var quickHangLimit = true' in experimental and experimental.count('"quickHangLimit"') == 2
assert 'static let version = "2.7.0"' in shared and 'static let build = 131' in shared and '("2.6.4", "Build 129:' in shared
print('v2.6.5 contracts passed: learned early start, sooner hang limit, switches, version')

# ---- 2.7.0: iPhone and iPad interface (no hot-path change). Source contracts only; nothing here is a device result. ----
project_text = read('project.yml')
assert 'UISupportedInterfaceOrientations~ipad: [UIInterfaceOrientationPortrait, UIInterfaceOrientationPortraitUpsideDown' in project_text
assert 'TARGETED_DEVICE_FAMILY: "1,2"' in project_text
orientation = read_source('OrientationLock')
assert 'if MainActor.assumeIsolated({ OrientationLock.isPad }) { return .all }' in orientation and 'guard !isPad else { return }' in orientation
root = read_source('ScreenTranslatorApp')
assert '.tabViewStyle(.sidebarAdaptable)' in root and 'KeyCommands(engine: model.engine' in root
assert root.count('value: AppTab.') == 4
keys = read_source('KeyCommands')
for shortcut in ('key("Translate", "1")', 'key("Choose languages", "l")', 'key("Copy translation", "c", [.command, .shift])'):
    assert shortcut in keys, shortcut
library = read_source('LibraryScreen')
assert 'NavigationSplitView {' in library and 'LibraryDetail(engine: engine, item: item).id(id)' in library
assert 'selection.subtract(ids)' in library and 'router.libraryFocus' in library
settings_home = read_source('SettingsViews')
assert '@EngineFacts(SettingsSummaryFacts.read) private var summary' in settings_home
assert '@EnvironmentObject var engine: TranslatorEngine' not in settings_home and 'NavigationSplitView {' in settings_home
assert '@EnvironmentObject private var engine: TranslatorEngine' not in read_source('CustomizationViews')
compose = read_source('ComposeBar')
assert 'breaks(value) == breaks(old) + 1' in compose and '.keyboardShortcut(.return, modifiers: .command)' in compose
assert '.onDrop(of: [.image, .plainText, .text]' in compose
assert 'action: n.action.map { run -> () -> Void in { center.dismiss(); run() } }' in read_source('Feedback')
assert 'func openLibraryItem(_ id: UUID)' in read_source('AppRouter')
assert 'router.openLibraryItem($0)' in read_source('TranslateScreen')
assert 'ScreenShape.aspect' in read_source('AreaEditor') and '9 / 19.5)' not in read_source('AreaEditor').split('ScreenShape')[0]
assert '.keyboardShortcut(.cancelAction)' in read_source('FocusMode')
assert 'static let version = "2.7.0"' in shared and 'static let build = 131' in shared and '("2.7.0", "Build 131:' in shared
assert project_text.count('"2.7.0"') == 3 and project_text.count('"131"') == 3
print('v2.7.0 contracts passed: iPad orientation and split views, sidebar tabs, keyboard shortcuts, compose fixes, notice undo, version')
