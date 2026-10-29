import copy
import unittest
from compare_hybrid import assess, HYBRID_EVIDENCE
from compare_performance import STATISTICS


class HybridGateTests(unittest.TestCase):
    def setUp(self):
        self.old = {'appVersion': 'old', 'hardwareModel': 'test', 'systemVersion': 'test',
                    'settings': {'speed': 'balanced', 'lowLatencyTranslation': False,
                                 'temporaryMemoryTest': True, 'startingRAMEntries': '0'},
                    'counters': dict.fromkeys(('enqueueFailed', 'modelFailures', 'handoffExpired', 'unpresentedConfirmed'), 0),
                    'health': {'integrity': 'ok', 'migrationStatus': 'ready', 'totalEntries': 100,
                               'readyEntries': 100, 'pendingWrites': 0, 'failedWrites': 0, 'conflicts': 0},
                    'distributions': {'enqueueLatencyMs': dict(count=100, **dict.fromkeys(STATISTICS, 600))}}
        self.new = copy.deepcopy(self.old)
        self.new['settings']['hybridTranslation'] = True
        self.new['counters'].update(hybridLowBatches=30, confirmedModelBatches=30, hybridPreviewEnqueues=30)
        self.new['distributions']['hybridFirstEnqueueMs'] = dict(count=100, **dict.fromkeys(STATISTICS, 450))
        self.new['distributions']['hybridFinalEnqueueMs'] = dict(count=100, **dict.fromkeys(STATISTICS, 600))
        self.evidence = dict.fromkeys(HYBRID_EVIDENCE, True)

    def test_both_first_and_final_required(self):
        self.assertTrue(assess(self.old, self.new, self.evidence)['accepted'])
        self.new['distributions']['hybridFinalEnqueueMs']['p95'] = 601
        self.assertFalse(assess(self.old, self.new, self.evidence)['accepted'])

    def test_quick_preview_does_not_hide_missing_final(self):
        del self.new['distributions']['hybridFinalEnqueueMs']
        self.assertFalse(assess(self.old, self.new, self.evidence)['accepted'])

    def test_both_models_must_run(self):
        self.new['counters']['hybridLowBatches'] = 0
        self.assertFalse(assess(self.old, self.new, self.evidence)['accepted'])

    def test_preview_population_must_match(self):
        self.new['settings']['startingHybridPreviewEntries'] = '100'
        self.assertFalse(assess(self.old, self.new, self.evidence)['accepted'])

    def test_no_quality_assumption(self):
        self.assertFalse(assess(self.old, self.new)['accepted'])
        self.evidence['hybrid_preview_wording_acceptable'] = False
        self.assertFalse(assess(self.old, self.new, self.evidence)['accepted'])

    def test_final_coverage_vetoes_speed(self):
        self.new['counters']['hybridRefinementsSuperseded'] = 1
        self.assertFalse(assess(self.old, self.new, self.evidence)['accepted'])


if __name__ == '__main__': unittest.main()
