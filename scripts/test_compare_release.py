import copy
import unittest
from compare_release import assess, RELEASE_EVIDENCE
from compare_performance import STATISTICS


class ReleaseGateTests(unittest.TestCase):
    def setUp(self):
        run = {'appVersion': 'baseline', 'hardwareModel': 'test', 'systemVersion': 'test',
               'settings': {'speed': 'balanced', 'lowLatencyTranslation': 'false', 'startingRAMEntries': '0'},
               'counters': dict.fromkeys(('enqueueFailed', 'modelFailures', 'handoffExpired', 'unpresentedConfirmed'), 0),
               'health': {'integrity': 'ok', 'migrationStatus': 'ready', 'totalEntries': 1500,
                          'readyEntries': 1200, 'failedWrites': 0, 'pendingWrites': 0, 'conflicts': 0},
               'distributions': {'enqueueLatencyMs': dict(count=100, **dict.fromkeys(STATISTICS, 600))}}
        temporary = copy.deepcopy(run)
        temporary['settings']['temporaryMemoryTest'] = 'true'
        self.baselines = {'normal': [run], 'temporaryMemory': [temporary]}
        self.candidates = {'normal': copy.deepcopy(run), 'temporaryMemory': copy.deepcopy(temporary)}
        for mode, candidate in self.candidates.items():
            for key in STATISTICS:
                candidate['distributions']['enqueueLatencyMs'][key] = 540 if mode == 'normal' else 450
        self.evidence = dict.fromkeys(RELEASE_EVIDENCE, True)

    def test_both_independent_cohorts_must_pass_all_targets(self):
        self.assertTrue(assess(self.baselines, self.candidates, self.evidence)['accepted'])
        self.candidates['temporaryMemory']['distributions']['enqueueLatencyMs']['p50'] = 451
        self.assertFalse(assess(self.baselines, self.candidates, self.evidence)['accepted'])

    def test_tail_regression_cannot_hide_behind_median(self):
        self.candidates['temporaryMemory']['distributions']['enqueueLatencyMs']['p95'] = 610
        self.assertFalse(assess(self.baselines, self.candidates, self.evidence)['accepted'])

    def test_fast_temporary_run_cannot_hide_normal_regression(self):
        self.candidates['normal']['distributions']['enqueueLatencyMs']['mean'] = 601
        self.assertFalse(assess(self.baselines, self.candidates, self.evidence)['accepted'])

    def test_every_older_baseline_must_be_beaten(self):
        faster_old = copy.deepcopy(self.baselines['temporaryMemory'][0])
        faster_old['distributions']['enqueueLatencyMs']['p50'] = 550
        self.baselines['temporaryMemory'].append(faster_old)
        self.assertFalse(assess(self.baselines, self.candidates, self.evidence)['accepted'])

    def test_no_quality_or_upgrade_evidence_is_not_a_pass(self):
        self.assertFalse(assess(self.baselines, self.candidates)['accepted'])
        self.evidence['saved_memory_survives_upgrade'] = False
        self.assertFalse(assess(self.baselines, self.candidates, self.evidence)['accepted'])

    def test_missing_health_cannot_be_assumed_healthy(self):
        del self.candidates['normal']['health']['integrity']
        self.assertFalse(assess(self.baselines, self.candidates, self.evidence)['accepted'])

    def test_entry_loss_vetoes_speed(self):
        self.candidates['normal']['health']['readyEntries'] -= 1
        self.assertFalse(assess(self.baselines, self.candidates, self.evidence)['accepted'])

    def test_counts_and_modes_cannot_be_mixed(self):
        self.candidates['temporaryMemory']['distributions']['enqueueLatencyMs']['count'] = 49
        self.assertFalse(assess(self.baselines, self.candidates, self.evidence)['accepted'])
        self.candidates['temporaryMemory']['distributions']['enqueueLatencyMs']['count'] = 100
        self.candidates['temporaryMemory']['settings']['temporaryMemoryTest'] = False
        self.assertFalse(assess(self.baselines, self.candidates, self.evidence)['accepted'])

    def test_missing_cohort_is_incomplete(self):
        del self.candidates['normal']
        self.assertFalse(assess(self.baselines, self.candidates, self.evidence)['accepted'])

    def test_reliability_vetoes_speed(self):
        self.candidates['temporaryMemory']['counters']['unpresentedConfirmed'] = 1
        self.assertFalse(assess(self.baselines, self.candidates, self.evidence)['accepted'])


if __name__ == '__main__': unittest.main()
