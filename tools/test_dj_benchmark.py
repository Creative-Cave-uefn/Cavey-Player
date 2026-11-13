import json
import math
from pathlib import Path
import shutil
import struct
import tempfile
import unittest
import wave

from dj_benchmark import Plan, filter_graph, main, measure


class BenchmarkTests(unittest.TestCase):
    def test_rejects_invalid_plans(self):
        for change in [{'outMs': -1}, {'lengthMs': 0}, {'rate': float('nan')}, {'swapMs': 3000}]:
            with self.assertRaises(ValueError):
                Plan.read({'outMs': 1000, 'inMs': 0, 'lengthMs': 2000, 'rate': 1, 'technique': 'beatBlend', **change})

    def test_filter_graph_has_overlap_plateau_and_bass_swap(self):
        graph = filter_graph(Plan(1000, 0, 2000, 1, 1, 'beatBlend', 1000))
        self.assertIn('0.2', graph)
        self.assertIn('highpass=f=220', graph)
        self.assertIn('normalize=0', graph)

    @unittest.skipUnless(shutil.which('ffmpeg'), 'FFmpeg unavailable')
    def test_synthetic_pair_renders_both_systems_and_measures_pcm(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name, frequency in [('one', 220), ('two', 330)]:
                with wave.open(str(root / f'{name}.wav'), 'wb') as output:
                    output.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
                    output.writeframes(b''.join(struct.pack('<h', round(6000 * math.sin(2 * math.pi * frequency * i / 48000)))
                                               for i in range(48000 * 5)))
            row = {'kind': 'decision', 'from': 'one', 'to': 'two', 'technique': 'beatBlend',
                   'outMs': 1000, 'inMs': 0, 'lengthMs': 2000, 'rate': 1, 'inGain': 1, 'swapMs': 1000,
                   'baseline': {'outMs': 1000, 'inMs': 0, 'lengthMs': 2000, 'rate': 1, 'inGain': 1}}
            journal = root / 'journal.jsonl'
            journal.write_text(json.dumps(row) + '\n', encoding='utf-8')
            files = root / 'files.json'
            files.write_text(json.dumps({name: str(root / f'{name}.wav') for name in ['one', 'two']}), encoding='utf-8')
            out = root / 'out'
            self.assertEqual(main(['--journal', str(journal), '--files', str(files), '--out', str(out)]), 0)
            report = json.loads((out / 'report.json').read_text(encoding='utf-8'))
            for result in report['renders'].values():
                self.assertTrue(result['pcmIntegrity'])
                self.assertIsNotNone(result['integratedLufs'])
                self.assertIsNotNone(result['truePeakDbtp'])
            self.assertEqual(set(json.loads((out / 'blind-key.json').read_text()).values()), {'AutoMix', 'Adaptive'})
            self.assertEqual(measure('ffmpeg', out / 'A.wav')['nonfiniteSamples'], 0)


if __name__ == '__main__':
    unittest.main()
