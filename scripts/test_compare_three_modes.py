import unittest
from compare_three_modes import compare, distribution

class RecordedModeComparisonTests(unittest.TestCase):
    def session(self, mode, latency):
        return {'hardwareModel': 'iPhoneTest1,1', 'systemVersion': '26.5',
                'measurementBoundary': 'First OCR sighting to PiP enqueue',
                'settings': {'source': 'pt', 'target': 'en', 'translationSystem': mode},
                'translationModes': {'active': mode, 'events': [
                    e for i in range(20) for e in [
                        {'session': 'test', 'caption': str(i), 'revision': 1, 'mode': mode,
                         'reason': 'recovery_decision_source_mismatch'},
                        {'session': 'test', 'caption': str(i), 'revision': 1, 'mode': mode,
                         'testMode': 'temporaryMemory', 'source': 'pt', 'target': 'en', 'thermal': 0,
                         'reason': 'pip_enqueue_recovery_success', 'durationMs': latency}]]}}
    def test_no_manufactured_empty_percentiles(self):
        self.assertIsNone(distribution([])['p95'])
        self.assertIsNone(distribution([1])['p95'])
    def test_synthetic_gate_math_only(self):
        sessions = [self.session('legacy', 1000), self.session('hybridRecovery', 750), self.session('lowLatency', 650)]
        result = compare(sessions, True, True)
        self.assertTrue(result['controlledConditionsAttested'])
        self.assertEqual(result['gates'][0]['status'], 'pass')
        self.assertEqual(result['qualityParity'].split(';')[0], 'unverified')
    def test_attestation_and_device_mismatch_withhold_claim(self):
        sessions = [self.session(m, 1000) for m in ['legacy', 'hybridRecovery', 'lowLatency']]
        sessions[2]['hardwareModel'] = 'different'
        result = compare(sessions)
        self.assertFalse(result['controlledConditionsAttested'])
        self.assertTrue(all(g['status'] == 'unverified' for g in result['gates']))
    def test_regression_is_not_hidden(self):
        sessions = [self.session('legacy', 1000), self.session('hybridRecovery', 1100), self.session('lowLatency', 650)]
        self.assertEqual(compare(sessions, True, True)['gates'][0]['status'], 'fail')

if __name__ == '__main__':
    unittest.main()
