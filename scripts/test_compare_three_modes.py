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
        # 2.5.0 (changed with the code): two modes. The Hybrid pass/fail gates are gone; a Hybrid session from an
        # older report is read and left out, and Low Latency against Legacy is reported without a claim.
        sessions = [self.session('legacy', 1000), self.session('hybridRecovery', 750), self.session('lowLatency', 650)]
        result = compare(sessions, True, True, True)
        self.assertTrue(result['controlledConditionsAttested'])
        self.assertEqual(result['ignoredRemovedModeSessions'], 1)
        self.assertTrue(all(g['mode'] == 'lowLatency' for g in result['gates']))
        self.assertTrue(all('hybridRecovery' not in key for key in result['cohorts']))
        self.assertEqual(result['gates'][0]['status'], 'reported_no_claim')
        self.assertEqual(result['qualityParity'].split(';')[0], 'unverified')
    def test_attestation_and_device_mismatch_withhold_claim(self):
        sessions = [self.session(m, 1000) for m in ['legacy', 'hybridRecovery', 'lowLatency']]
        sessions[2]['hardwareModel'] = 'different'
        result = compare(sessions)
        self.assertFalse(result['controlledConditionsAttested'])
        self.assertTrue(all(g['status'] == 'unverified' for g in result['gates']))
    def test_matching_hardware_alone_does_not_prove_matching_content(self):
        sessions = [self.session(m, 1000) for m in ['legacy', 'hybridRecovery', 'lowLatency']]
        self.assertFalse(compare(sessions, True, True)['controlledConditionsAttested'])
    def test_regression_is_not_hidden(self):
        sessions = [self.session('legacy', 1000), self.session('lowLatency', 1100)]
        gate = compare(sessions, True, True, True)['gates'][0]
        self.assertTrue(all(v > 0 for v in gate['changesPercent'].values()), 'a slower mode shows as slower')
    def test_only_removed_mode_sessions(self):
        result = compare([self.session('hybridRecovery', 900)], True, True, True)
        self.assertFalse(result['controlledConditionsAttested'])
        self.assertEqual(result['ignoredRemovedModeSessions'], 1)

if __name__ == '__main__':
    unittest.main()
