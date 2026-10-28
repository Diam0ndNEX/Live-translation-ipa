import copy
import unittest
from compare_performance import compare, METRICS, STATISTICS, QUALITY_KEYS

class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.old = {'appVersion':'baseline', 'hardwareModel':'test', 'systemVersion':'test',
                    'settings':{'lowLatencyTranslation':'false','speed':'balanced'},
                    'counters':dict.fromkeys(('enqueueFailed','modelFailures','handoffExpired','unpresentedConfirmed'),0),
                    'distributions':{key:dict(count=100, **dict.fromkeys(STATISTICS,100)) for key in METRICS}}
        self.new = copy.deepcopy(self.old)
        self.evidence = dict.fromkeys(QUALITY_KEYS,True)
        for stage in self.new['distributions'].values():
            for key in STATISTICS: stage[key] = 90

    def test_requires_independent_quality_evidence(self):
        self.assertFalse(compare(self.old,self.new)['accepted'])
        self.assertTrue(compare(self.old,self.new,self.evidence)['accepted'])

    def test_missing_data_cannot_shrink_denominator(self):
        del self.new['distributions']['ocrMs']
        result = compare(self.old,self.new,self.evidence)
        self.assertEqual(result['total'],40)
        self.assertEqual(result['wins'],36)
        self.assertFalse(result['accepted'])

    def test_no_low_latency_substitution(self):
        self.new['settings']['lowLatencyTranslation']='1'
        self.assertFalse(compare(self.old,self.new,self.evidence)['accepted'])

    def test_reliability_vetoes_speed(self):
        self.new['counters']['enqueueFailed']=1
        self.assertFalse(compare(self.old,self.new,self.evidence)['accepted'])

    def test_exact_ninety_percent_boundary(self):
        for key in STATISTICS: self.new['distributions']['ocrMs'][key]=101
        self.assertTrue(compare(self.old,self.new,self.evidence)['accepted'])
        self.new['distributions']['queueMs']['p95']=101
        self.assertFalse(compare(self.old,self.new,self.evidence)['accepted'])

    def test_settings_boolean_encodings_match(self):
        self.old['settings']['adaptiveConfirmation']='false'
        self.new['settings']['adaptiveConfirmation']='0'
        self.assertTrue(compare(self.old,self.new,self.evidence)['accepted'])

    def test_small_samples_do_not_claim_p95(self):
        self.new['distributions']['modelBatchMs']['count']=4
        self.assertFalse(compare(self.old,self.new,self.evidence)['accepted'])

if __name__ == '__main__': unittest.main()
