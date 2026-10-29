#!/usr/bin/env python3
"""Report matched, recorded three-mode enqueue cohorts; never synthesize timings."""
import argparse
import json
import math
from pathlib import Path
import statistics
import zipfile

MODES = {'legacy', 'hybridRecovery', 'lowLatency'}
IGNORED_SETTINGS = {'translationSystem', 'lowLatencyTranslation', 'hybridTranslation', 'translationSystemMigration'}

def read_session(path):
    path = Path(path)
    if path.suffix.lower() == '.zip':
        with zipfile.ZipFile(path) as archive:
            names = [n for n in archive.namelist() if n.endswith('session.json')]
            if len(names) != 1:
                raise ValueError('Expected one canonical session.json')
            return json.loads(archive.read(names[0]))
    return json.loads(path.read_text())

def distribution(values):
    values = sorted(x for x in values if isinstance(x, (int, float)) and math.isfinite(x) and x >= 0)
    def percentile(p):
        return values[max(0, math.ceil(len(values) * p) - 1)] if values else None
    return {'count': len(values), 'mean': statistics.mean(values) if values else None,
            'median': statistics.median(values) if values else None,
            'p90': percentile(.9) if len(values) >= 10 else None,
            'p95': percentile(.95) if len(values) >= 20 else None,
            'observedMaximum': max(values) if values else None}

def cohorts(session):
    events = session.get('translationModes', {}).get('events', [])
    reasons, samples, seen = {}, {}, set()
    for e in events:
        identity = (e.get('session'), e.get('caption'), e.get('revision'))
        reason = e.get('reason', '')
        if reason.startswith('recovery_decision_'):
            reasons[identity] = reason.removeprefix('recovery_decision_')
        if not reason.startswith('pip_enqueue_') or identity in seen:
            continue
        seen.add(identity)
        if reason == 'pip_enqueue_memory_hit':
            route = 'memory'
        elif 'speculation_match' in reason:
            route = 'successful_speculation'
        elif reason == 'pip_enqueue_confirmed_fresh' or reasons.get(identity) == 'speculation_absent':
            route = 'confirmed_fresh'
        else:
            route = 'recovery'
        mode = e.get('mode', session.get('translationModes', {}).get('active'))
        key = '|'.join([mode or 'unknown', e.get('testMode', 'unknown'), e.get('source', 'unknown'),
                        e.get('target', 'unknown'), str(e.get('thermal', 'unknown')), route])
        if e.get('durationMs') is not None:
            samples.setdefault(key, []).append(e['durationMs'])
            overall = key.rsplit('|', 1)[0] + '|overall'
            samples.setdefault(overall, []).append(e['durationMs'])
    return {key: distribution(values) for key, values in sorted(samples.items())}

def compare(sessions, matched_memory=False, counterbalanced=False, matched_content=False):
    errors = []
    modes = [s.get('translationModes', {}).get('active') for s in sessions]
    if set(modes) != MODES or len(sessions) != 3:
        errors.append('Exactly one recorded session per mode is required')
    if not matched_content:
        errors.append("Matched content and equivalent retained capture windows are not attested")
    if not matched_memory:
        errors.append('Equivalent isolated starting memory snapshots/fresh input sets are not attested')
    if not counterbalanced:
        errors.append('Counterbalanced repeated test order is not attested')
    for field in ['hardwareModel', 'systemVersion', 'measurementBoundary']:
        values = [s.get(field) for s in sessions]
        if not values[0] or any(v != values[0] for v in values):
            errors.append(field + ' differs or is unavailable')
    settings = [{k: v for k, v in s.get('settings', {}).items() if k not in IGNORED_SETTINGS} for s in sessions]
    if not settings[0] or any(x != settings[0] for x in settings):
        errors.append('Non-mode settings or starting RAM cohorts differ')
    results = {mode or 'unknown': cohorts(s) for mode, s in zip(modes, sessions)}
    gates = []
    baseline = results.get('legacy', {})
    for mode in ['hybridRecovery', 'lowLatency']:
        current = results.get(mode, {})
        for key, old in baseline.items():
            equivalent = mode + key[len('legacy'):]
            new = current.get(equivalent)
            route = key.rsplit('|', 1)[-1]
            item = {'mode': mode, 'cohort': equivalent, 'status': 'unverified'}
            if errors or not new or old['count'] < 20 or new['count'] < 20:
                item['reason'] = 'Unmatched conditions, absent path or fewer than 20 samples'
            else:
                changes = {metric: 100 * (new[metric] / old[metric] - 1)
                           for metric in ['mean', 'p95'] if old[metric] and new[metric] is not None}
                item['changesPercent'] = changes
                if mode == 'hybridRecovery' and route == 'recovery':
                    item['status'] = 'pass' if len(changes) == 2 and all(v <= -20 for v in changes.values()) else 'fail'
                elif mode == 'hybridRecovery' and route == 'overall' and '|temporaryMemory|' in key:
                    item['status'] = 'pass' if len(changes) == 2 and all(v <= -10 for v in changes.values()) else 'fail'
                elif route in ['memory', 'successful_speculation']:
                    item['status'] = 'investigate' if any(v > 5 for v in changes.values()) else 'pass'
                else:
                    item['status'] = 'reported_no_claim'
            gates.append(item)
    return {'controlledConditionsAttested': not errors, 'limitations': errors,
            'cohorts': results, 'gates': gates,
            'qualityParity': 'unverified; requires independent multilingual rubric and visual review',
            'physicalPresentation': 'unmeasured; timings end at PiP enqueue',
            'scope': 'bounded retained event samples; absent OCR captions require external ground truth',
            'uncertainty': 'Single exported cohorts do not establish run-to-run variance or statistical quality equivalence; repeat matched, counterbalanced runs'}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('sessions', nargs=3)
    parser.add_argument('--matched-content', action='store_true')
    parser.add_argument('--matched-memory', action='store_true')
    parser.add_argument('--counterbalanced', action='store_true')
    args = parser.parse_args()
    report = compare([read_session(p) for p in args.sessions], args.matched_memory, args.counterbalanced, args.matched_content)
    print(json.dumps(report, indent=2, sort_keys=True))

if __name__ == '__main__':
    main()
