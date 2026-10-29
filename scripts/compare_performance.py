#!/usr/bin/env python3
"""Compare matched device exports. No synthetic speedup or visual-quality inference."""
import argparse
import json
import math
from pathlib import Path
import zipfile

# Fixed before measuring v1.7.0; missing observations never shrink the denominator.
METRICS = ('enqueueLatencyMs', 'ocrMs', 'finalOCRMs', 'confirmationMs', 'queueMs',
           'processingMs', 'deliveryFilteringMs', 'renderingMs', 'memoryLookupMs', 'modelBatchMs')
STATISTICS = ('p50', 'mean', 'p90', 'p95')
MATCH_SETTINGS = ('source', 'target', 'mode', 'speed', 'stability', 'area', 'customY0',
                  'customY1', 'ocrConfidence', 'ocrCorrection', 'adaptiveConfirmation',
                  'adaptiveOCR', 'skipUnchanged', 'freshTranslationTest', 'detailedCollection',
                  'translateAhead', 'remember', 'privateSession', 'displayPolicy', 'minDisplay',
                  'boost', 'subtitleTracking', 'selectiveSpeculation', 'speculationConfidence',
                  'steadyCaptions', 'protectConfirmedPresentation', 'coolMode', 'frameRot',
                  'incrementalBatchRecovery', 'subtitleAwareChangeDetection', 'preserveRelatedMovieGroups')
QUALITY_KEYS = ('same_video_and_boundaries', 'comparable_memory_and_startup',
                'wording_no_worse', 'coverage_no_worse', 'order_no_worse', 'flicker_no_worse',
                'long_session_reliability_no_worse', 'thermal_and_battery_no_worse')


def read(path):
    path = Path(path)
    if path.suffix == '.zip':
        with zipfile.ZipFile(path) as archive:
            return json.loads(archive.read('session.json'))
    return json.loads(path.read_text())


def normalized(value):
    if str(value).lower() in ('true', '1'): return True
    if str(value).lower() in ('false', '0'): return False
    return value


def test_mode(settings):
    if normalized(settings.get('freshTranslationTest', 'false')): return 'freshRequests'
    if normalized(settings.get('temporaryMemoryTest', 'false')): return 'temporaryMemory'
    return 'normal'


def compare(baseline, candidate, evidence=None):
    issues = []
    for label, data in (('baseline', baseline), ('candidate', candidate)):
        if normalized(data['settings'].get('lowLatencyTranslation', 'false')) is not False:
            issues.append(f'{label}: low-latency models must be OFF')
        if data['settings'].get('speed') != 'balanced':
            issues.append(f'{label}: Balanced is required')
    for key in ('hardwareModel', 'systemVersion'):
        if baseline.get(key) != candidate.get(key): issues.append(f'Mismatched {key}')
    for key in MATCH_SETTINGS:
        if normalized(baseline['settings'].get(key)) != normalized(candidate['settings'].get(key)):
            issues.append(f'Mismatched setting: {key}')
    if normalized(baseline['settings'].get('suppressOwnInterface', 'false')) != normalized(candidate['settings'].get('suppressOwnInterface', 'false')):
        issues.append('Mismatched own-interface suppression; repeat with matched measurement boundaries')
    if normalized(baseline['settings'].get('hybridTranslation', 'false')) != normalized(candidate['settings'].get('hybridTranslation', 'false')):
        issues.append('Mismatched hybrid model mode; compare first-result and final-quality evidence separately')
    if test_mode(baseline['settings']) != test_mode(candidate['settings']):
        issues.append('Mismatched translation test mode')
    a, b = baseline['settings'].get('startingRAMEntries'), candidate['settings'].get('startingRAMEntries')
    if a is not None and b is not None and int(a) != int(b):
        issues.append('Different starting RAM populations; repeat under matched cache conditions')
    if int(baseline["settings"].get("startingHybridPreviewEntries", 0)) != int(candidate["settings"].get("startingHybridPreviewEntries", 0)):
        issues.append("Different starting hybrid preview populations")
    cells = []
    for metric in METRICS:
        old = baseline['distributions'].get(metric, {})
        new = candidate['distributions'].get(metric, {})
        for statistic in STATISTICS:
            a, b = old.get(statistic), new.get(statistic)
            usable = min(old.get('count', 0), new.get('count', 0)) >= 20 and all(
                isinstance(v, (int, float)) and math.isfinite(v) and v >= 0 for v in (a, b))
            cells.append({'metric': metric, 'statistic': statistic, 'baseline_ms': a,
                          'candidate_ms': b, 'result': ('win' if b < a else 'tie' if b == a else 'regression') if usable else 'missing'})
    wins = sum(cell['result'] == 'win' for cell in cells)
    for key in ('enqueueFailed', 'modelFailures', 'handoffExpired', 'unpresentedConfirmed'):
        a, b = baseline['counters'].get(key), candidate['counters'].get(key)
        if a is None or b is None: issues.append(f'Missing reliability counter: {key}')
        elif b > a: issues.append(f'Reliability counter increased: {key} ({a} -> {b})')
    for key in ('failedWrites', 'conflicts', 'pendingWrites'):
        if candidate.get('health', {}).get(key, 0) > baseline.get('health', {}).get(key, 0):
            issues.append(f'Memory health worsened: {key}')
    quality_confirmed = isinstance(evidence, dict) and all(evidence.get(k) is True for k in QUALITY_KEYS)
    complete = all(cell['result'] != 'missing' for cell in cells)
    return {'baseline': baseline['appVersion'], 'candidate': candidate['appVersion'],
            'wins': wins, 'total': len(cells), 'win_fraction': wins / len(cells),
            'comparable_and_reliable': not issues, 'issues': issues,
            'quality_and_workload_verified': quality_confirmed,
            'accepted': complete and wins / len(cells) >= .9 and not issues and quality_confirmed,
            'measurement_boundary': 'First OCR sighting to PiP enqueue; physical display unmeasured',
            'cells': cells}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline')
    parser.add_argument('candidate')
    parser.add_argument('--quality-evidence', help='JSON with reviewed same-workload and quality checks')
    args = parser.parse_args()
    evidence = json.loads(Path(args.quality_evidence).read_text()) if args.quality_evidence else None
    result = compare(read(args.baseline), read(args.candidate), evidence)
    print(json.dumps(result, indent=2, allow_nan=False))
    return 0 if result['accepted'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
