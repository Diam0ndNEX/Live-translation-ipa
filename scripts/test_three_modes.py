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
        ("            // 2.2.3 (L2): a detached speculative call must not erase the newer confirmed call's in-flight set.\n            if modelUnitKeysInFlight == Set(items.map { $0.key }) {\n                modelUnitKeysInFlight.removeAll()\n                modelContextInFlight = nil\n            }\n",
         "            modelUnitKeysInFlight.removeAll()\n            modelContextInFlight = nil\n"),
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
    'guard !busy, queued == nil else',
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
assert core.count('case legacy, hybridRecovery, lowLatency') == 1
assert 'self.system == .hybridRecovery' in core
assert 'if result == nil, self.system == .hybridRecovery' in core
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
assert 'modeCoordinator.adaptiveHybrid = flag("adaptiveSpeculation", true)' in engine
assert 'hybrid_simultaneous_model_overlap_ms' in engine and 'noteOverlappingRecovery(serviceMilliseconds:' in engine
assert 'lastModePreparationPair = ""' in function(engine, 'invalidatePending'), 'Capture changes must reset mode session readiness throttle'
assert 'lastModePreparationAt = .distantPast' in function(engine, 'invalidatePending')
assert '!backendActivity.executing' in engine, 'Avoid live inference contention during readiness checks'
assert 'pip.isShowingIdenticalFrame' in engine
assert 'pip_held_unchanged' in engine
assert 'installedCheckTTL: Double = 30' in service
assert 'backend_availability_ms' in service
assert 'backend_task_dispatch_ms' in service
assert 'hybrid_cross_strategy_overlap' in service
assert 'model_batch_completed", serviceMs' in service
assert 'HybridAdmissionPolicy' in core
assert 'hybrid_hedged_recovery' in core
assert 'hybrid_obsolete_speculation_draining' in core
assert 'hybrid_losing_request_draining' in core
assert 'if system != .hybridRecovery {' in core
assert 'self.committed != caption' in core
assert 'sortedDefault' in core and 'recoveryMedian * 0.75' in core
assert 'hybrid_hedged_recovery' in read_source('DiagnosticArchive')
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
# The two new behaviours are switchable, default ON, pinned at session start, and named in every report.
for setting, pinned, accessor, arm in (('hybridPinnedBackend', 'hybridPinPinnedKey', 'hybridPinnedBackend', 'hybridPinAB'),
                                       ('deferArmedSpeculation', 'armedDeferPinnedKey', 'deferArmedSpeculation', 'armedDeferAB')):
    assert f'= "{setting}"' in work and f'?? true, forKey: {pinned})' in work, setting + ' is pinned when a session starts'
    assert f'(UserDefaults.standard.object(forKey: {pinned}) as? Bool) ?? true' in work, setting + ' defaults to on'
    assert f'@AppStorage("{setting}") private var {setting} = true' in experimental and experimental.count(f'"{setting}"') >= 2, setting + ' has a toggle and resets'
    assert f'if TranslationHotPathAB.{accessor} {{ settings["{arm}"] = "on" }}' in diagnostics
    assert archive.count(f'"{arm}"') == 3, arm + ': export allowlist, cohort keys and the report column'
# Hybrid pin: lives in the coordinator, off unless the app turns it on, and only Hybrid uses it.
pin = read('Shared/TranslationSystem+BackendPin.swift')
assert 'struct HybridBackendPin' in pin and 'static let fallbackHold = 20.0' in pin
assert '(!fastInstalled || now < defaultUntil) ? .appleDefault : .lowLatency' in pin
assert 'var hybridPinnedBackend = false' in core, 'reference behaviour stays the coordinator default'
assert 'var pinActive: Bool { system == .hybridRecovery && hybridPinnedBackend }' in core
assert 'modeCoordinator.hybridPinnedBackend = TranslationHotPathAB.hybridPinnedBackend' in engine
assert 'if self.pinActive { self.backendPin.noteLowLatencyFailure(now: self.clock()) }' in core
for reason in ('hybrid_pin_low_latency', 'hybrid_pin_default', 'hybrid_pin_wait_matching',
               'hybrid_model_switch_low_latency', 'hybrid_model_switch_default', 'speculation_deferred_armed'):
    assert archive.count('"' + reason + '"') == 2, reason + ' must be in the mode reasons and the whole-session reasons'
assert '!self.modeCoordinator.pinnedToLowLatency &&' in engine
# Pinned or not, Low Latency output still never enters the shared memory namespace.
assert 'where output.strategies[i] == .appleDefault' in engine
# Deferral: only for a first sighting whose pixel check is armed, only for Apple Default work, never for confirmed text.
assert 'var pixelArmed: Bool? = nil' in shared
assert 'if p.pixelArmed == true, TranslationHotPathAB.deferArmedSpeculation {' in function(engine, 'handleContent')
assert function(engine, 'handleContent').index('if p.pixelArmed == true') > function(engine, 'handleContent').index('if p.stable == false {\n            //'), 'deferral sits inside the first-sighting branch'
assert 'let deferredArmed = !confirmed && packet.pixelArmed == true && TranslationHotPathAB.deferArmedSpeculation &&\n            modeCoordinator.nextSpeculativeStrategy == .appleDefault' in engine
assert 'let admitted = !deferredArmed && speculationAllowed' in engine
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
assert 'static let version = "2.4.0"' in shared and 'static let build = 117' in shared
assert read('project.yml').count('"2.4.0"') == 3 and read('project.yml').count('"117"') == 3
assert '("2.4.0", "Build 117:' in shared and '("2.3.9", "Build 116:' in shared
print('v2.4.0 source contracts passed: switchable pin and deferral (default on), unchanged OCR and confirmation evidence, forced re-read, direct model call, metadata-only diagnostics, version')

