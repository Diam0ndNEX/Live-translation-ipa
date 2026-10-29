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
for name in ['process', 'drain', 'speculate', 'cachedCaption', 'extractTexts', 'selectBlocks']:
    assert function(engine, name) == function(old('App/TranslatorEngine.swift'), name), name + ' Legacy policy changed'
assert read('App/TranslationMemoryStore.swift') == old('App/TranslationMemoryStore.swift')
assert old('App/TranslationMemoryStore.swift', 'origin/codex/screenlingo-v1.8.0-performance') == old('App/TranslationMemoryStore.swift')
for token in ['com.diam0ndnex.screenlingo', 'com.diam0ndnex.screenlingo.broadcast']:
    assert token in read('project.yml')
assert 'ScreenLingo/TranslationMemory' in engine
assert 'base: snapshot, lowLatency: false' in engine
assert 'where output.strategies[i] == .appleDefault' in engine
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
print('Legacy algorithm equivalence, installed schema/identity, no preview/refinement, bounded cache and model routing source contracts passed')
