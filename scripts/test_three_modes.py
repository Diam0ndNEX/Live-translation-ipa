#!/usr/bin/env python3
"""Contract checks supplement the real asynchronous Swift coordinator tests."""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[1]
base = 'e94542ce46cdb5b2426fdfd5dc258c932327762b'
def old(path, ref=base):
    return subprocess.check_output(['git', 'show', f'{ref}:{path}'], cwd=root, text=True)
def read(path):
    return (root / path).read_text()
def function(source, name):
    start = source.index('    private func ' + name + '(')
    end = source.find('\n    private func ', start + 1)
    return source[start:end if end != -1 else len(source)]
engine = read('App/TranslatorEngine.swift')
for name in ['process', 'drain', 'cachedCaption']:
    assert function(engine, name).replace('SharedTranslationWork.unitKey', 'PipelineSafety.cacheKey') == function(old('App/TranslatorEngine.swift'), name), name + ' Legacy model drain/assembly algorithm changed beyond verified exact-key delegation'
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
assert function(engine, 'extractTexts') == old_extract, 'Legacy extraction changed beyond preset-independent area routing'
old_select = function(reference_engine, 'selectBlocks').replace('if mode == .movie {', 'if flag("activeTextFocus", true) {')
assert function(engine, 'selectBlocks') == old_select, 'Legacy text selection changed beyond preset-independent focus routing'
assert 'if mode == .movie' not in engine, 'Recognition cannot be locked to the Movie category'
assert function(read('App/TranslationMemoryStore.swift'), 'createSchema') == function(old('App/TranslationMemoryStore.swift'), 'createSchema')
assert function(read('App/TranslationMemoryStore.swift'), 'upgradeSchemaV2') == function(old('App/TranslationMemoryStore.swift'), 'upgradeSchemaV2')
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
core = read('Shared/TranslationSystem.swift')
assert core.count('case legacy, hybridRecovery, lowLatency') == 1
assert 'self.system == .hybridRecovery' in core
assert 'if result == nil, self.system == .hybridRecovery' in core
assert 'lowOrder.count > 256' in core
assert 'preferredStrategy: .highFidelity' not in read('App/ModeTranslationService.swift')
assert '"26.6"' in read('.github/workflows/build.yml')
assert 'hybridPreview' not in engine
activity = engine[engine.index('    var translationActivity:'):engine.index('    private func refreshModePreparation')]
assert 'warmupStatus' not in activity, 'Readiness must not depend on an old mode\'s string label'
assert 'TranslationActivity.preparation' not in engine, 'Use observed preparation stages, not parsing status text'
assert 'modelReadiness.prepare(stage)' in engine
assert 'modelReadiness.finishExecution(success: true' in engine
assert 'modeService.activityChanged' in engine
assert 'backendActivity.liveReadiness(modelReadiness)' in engine
assert 'let activity = backendActivity.activity' in activity
assert 'heldByActualCall = true' in read('App/ModeTranslationService.swift')
service = read('App/ModeTranslationService.swift')
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
assert 'hybrid_hedged_recovery' in read('App/DiagnosticArchive.swift')
assert 'modeAvailabilityCheckMs' in read('App/Diagnostics.swift')
assert 'exportModeEventWindow()' in read('App/Diagnostics.swift')
assert 'backend_installed_cache_hit' in service
print('Legacy algorithm equivalence, installed schema/identity, no preview/refinement, bounded cache and model routing source contracts passed')
