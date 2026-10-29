#!/usr/bin/env python3
"""Compare an explicitly selected hybrid run against a single high-fidelity baseline.
First-visible speed and final-quality latency are independent, mandatory gates.
"""
import argparse
import json
import math
from pathlib import Path
from compare_performance import compare, normalized, read, test_mode, STATISTICS
from compare_release import RELEASE_EVIDENCE

HYBRID_EVIDENCE = (*RELEASE_EVIDENCE, 'hybrid_preview_wording_acceptable',
                   'hybrid_refinement_flicker_acceptable')


def assess(baseline, candidate, evidence=None):
    report = compare(baseline, candidate)
    issues = [x for x in report['issues'] if not x.startswith('Mismatched hybrid model mode;')]
    if normalized(baseline['settings'].get('hybridTranslation', 'false')) is not False:
        issues.append('Baseline must be the existing single high-fidelity mode')
    if normalized(candidate['settings'].get('hybridTranslation', 'false')) is not True:
        issues.append('Candidate must explicitly select Hybrid')
    for key in ('hybridLowBatches', 'confirmedModelBatches', 'hybridPreviewEnqueues'):
        if candidate.get('counters', {}).get(key, 0) < 1:
            issues.append(f'Both strategies/preview path not exercised: {key}')
    if 'hybridRefinementsSuperseded' not in candidate.get('counters', {}):
        issues.append('Missing high-fidelity refinement coverage evidence')
    if candidate.get('counters', {}).get('hybridRefinementsSuperseded', 0) > baseline['counters'].get('unpresentedConfirmed', 0):
        issues.append('High-fidelity refinement coverage worsened')
    factor = .75 if test_mode(candidate['settings']) == 'temporaryMemory' else .90
    cells = []
    old = baseline['distributions'].get('enqueueLatencyMs', {})
    for metric, ceiling in (('hybridFirstEnqueueMs', factor), ('hybridFinalEnqueueMs', 1.0)):
        new = candidate['distributions'].get(metric, {})
        for statistic in STATISTICS:
            a, b = old.get(statistic), new.get(statistic)
            usable = min(old.get('count', 0), new.get('count', 0)) >= 50 and all(
                isinstance(v, (int, float)) and math.isfinite(v) and v > 0 for v in (a, b))
            passed = usable and b <= a * ceiling
            cells.append({'metric': metric, 'statistic': statistic, 'baseline_ms': a,
                          'candidate_ms': b, 'passed': passed})
            if not passed: issues.append(f'{metric}/{statistic}: target not demonstrated')
    for key in ('integrity', 'migrationStatus', 'totalEntries', 'readyEntries', 'pendingWrites', 'failedWrites', 'conflicts'):
        if key not in candidate.get('health', {}) or key not in baseline.get('health', {}):
            issues.append(f'Incomplete memory evidence: {key}')
    for label, run in (('baseline', baseline), ('candidate', candidate)):
        if run.get('health', {}).get('integrity') != 'ok' or run.get('health', {}).get('migrationStatus') != 'ready':
            issues.append(f'{label}: memory integrity/migration readiness is not verified')
    for key in ('totalEntries', 'readyEntries'):
        if candidate.get('health', {}).get(key, -1) < baseline.get('health', {}).get(key, 0):
            issues.append(f'Saved-memory population decreased: {key}')
    quality = isinstance(evidence, dict) and all(evidence.get(k) is True for k in HYBRID_EVIDENCE)
    if not quality: issues.append('Independent preview/final quality and upgrade evidence incomplete')
    return {'accepted': not issues, 'issues': issues, 'cells': cells,
            'first_result_required_improvement': 1 - factor,
            'final_quality_regression_allowed': False,
            'boundary': 'First OCR sighting to enqueue; physical display unmeasured'}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('baseline'); p.add_argument('candidate'); p.add_argument('--quality-evidence')
    args = p.parse_args()
    evidence = json.loads(Path(args.quality_evidence).read_text()) if args.quality_evidence else None
    result = assess(read(args.baseline), read(args.candidate), evidence)
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['accepted'] else 2)


if __name__ == '__main__': main()
