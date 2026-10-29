#!/usr/bin/env python3
"""Strict v1.8.0 acceptance for independently matched normal/temporary cohorts.

Targets are fixed before candidate device measurements: at least 25% lower
end-to-end median/mean/P90/P95 in temporary mode and 10% lower in normal mode.
No synthetic replay or CI run can satisfy the independent quality evidence.
"""
import argparse
import json
import math
from pathlib import Path
from compare_performance import compare, read, test_mode, QUALITY_KEYS, STATISTICS

TARGETS = {'normal': .90, 'temporaryMemory': .75}
REQUIRED_HEALTH = ('integrity', 'migrationStatus', 'failedWrites', 'pendingWrites',
                   'conflicts', 'totalEntries', 'readyEntries')
RELEASE_EVIDENCE = (*QUALITY_KEYS, 'saved_memory_survives_upgrade',
                    'normal_and_temporary_banks_isolated')


def assess(baselines, candidates, evidence=None):
    issues, cohorts = [], {}
    for mode, factor in TARGETS.items():
        old_runs, candidate = baselines.get(mode, []), candidates.get(mode)
        if not old_runs or candidate is None:
            issues.append(f'{mode}: missing baseline or candidate cohort')
            continue
        reports = []
        for baseline in old_runs:
            report = compare(baseline, candidate)
            local = list(report['issues'])
            if test_mode(baseline['settings']) != mode or test_mode(candidate['settings']) != mode:
                local.append('Wrong normal/temporary cohort')
            cells = []
            old = baseline.get('distributions', {}).get('enqueueLatencyMs', {})
            new = candidate.get('distributions', {}).get('enqueueLatencyMs', {})
            for statistic in STATISTICS:
                a, b = old.get(statistic), new.get(statistic)
                usable = min(old.get('count', 0), new.get('count', 0)) >= 50 and all(
                    isinstance(v, (int, float)) and not isinstance(v, bool) and
                    math.isfinite(v) and v > 0 for v in (a, b))
                passed = usable and b <= a * factor
                cells.append({'statistic': statistic, 'baseline_ms': a, 'candidate_ms': b,
                              'maximum_ms': a * factor if usable else None, 'passed': passed})
                if not passed: local.append(f'End-to-end {statistic}: target not demonstrated')
            for label, run in (('baseline', baseline), ('candidate', candidate)):
                health = run.get('health', {})
                if any(k not in health for k in REQUIRED_HEALTH):
                    local.append(f'{label}: incomplete memory health evidence')
                if health.get('integrity') != 'ok' or health.get('migrationStatus') != 'ready':
                    local.append(f'{label}: memory not ready and healthy')
            for key in ('totalEntries', 'readyEntries'):
                a, b = baseline.get('health', {}).get(key), candidate.get('health', {}).get(key)
                if not isinstance(a, int) or not isinstance(b, int) or b < a:
                    local.append(f'Saved-memory population decreased or missing: {key}')
            reports.append({'baseline': baseline.get('appVersion'), 'candidate': candidate.get('appVersion'),
                            'end_to_end': cells, 'issues': local, 'passed': not local})
            issues.extend(f'{mode}: {item}' for item in local)
        cohorts[mode] = {'required_improvement': 1 - factor, 'comparisons': reports}
    quality = isinstance(evidence, dict) and all(evidence.get(k) is True for k in RELEASE_EVIDENCE)
    if not quality: issues.append('Independent quality, workload and upgrade evidence is incomplete')
    return {'accepted': not issues, 'issues': issues, 'cohorts': cohorts,
            'boundary': 'First OCR sighting to PiP enqueue; physical display unmeasured',
            'quality_and_upgrade_verified': quality}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--normal-baseline', action='append', required=True)
    p.add_argument('--temporary-baseline', action='append', required=True)
    p.add_argument('--normal-candidate', required=True)
    p.add_argument('--temporary-candidate', required=True)
    p.add_argument('--quality-evidence')
    args = p.parse_args()
    evidence = json.loads(Path(args.quality_evidence).read_text()) if args.quality_evidence else None
    result = assess({'normal': [read(x) for x in args.normal_baseline],
                     'temporaryMemory': [read(x) for x in args.temporary_baseline]},
                    {'normal': read(args.normal_candidate), 'temporaryMemory': read(args.temporary_candidate)}, evidence)
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['accepted'] else 2)


if __name__ == '__main__': main()
