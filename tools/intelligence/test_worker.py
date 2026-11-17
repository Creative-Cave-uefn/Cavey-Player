import importlib.util
import math
import os
from pathlib import Path
import shutil
import tempfile
import unittest
spec=importlib.util.spec_from_file_location('cave_worker',Path(__file__).with_name('worker.py'))
worker=importlib.util.module_from_spec(spec);spec.loader.exec_module(worker)
class WorkerTests(unittest.TestCase):
    def test_generic_music_is_not_voice_and_checkpoint_is_pinned(self):
        self.assertNotIn('Music',worker.VOICE_LABELS);self.assertNotIn('Song',worker.VOICE_LABELS)
        self.assertIn('Singing',worker.VOICE_LABELS);self.assertEqual(len(worker.MODEL_SHA256),64)
    def test_wrong_weights_rejected_before_loading_runtime(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t)/'wrong';p.write_bytes(b'wrong model')
            with self.assertRaisesRegex(ValueError,'model_hash_mismatch'):worker.verify_model(p)
    @unittest.skipUnless(os.environ.get('CAVEY_TEST_VOCAL_MODEL') and shutil.which('ffmpeg'),'Set CAVEY_TEST_VOCAL_MODEL for real inference')
    def test_real_cpu_inference_preserves_timing_and_provenance(self):
        r=worker.analyze(Path(__file__).resolve().parents[2]/'test/fixtures/a.mp3',Path(os.environ['CAVEY_TEST_VOCAL_MODEL']),shutil.which('ffmpeg'))
        self.assertEqual(r['durationMs'],3000);self.assertEqual(r['modelSha256'],worker.MODEL_SHA256)
        self.assertEqual(r['hopMs'],480);self.assertEqual(r['windowMs'],975);self.assertFalse(r['calibratedAbsence'])
        self.assertEqual(len(r['scores']),7);self.assertTrue(all(math.isfinite(v)and 0<=v<=1 for v in r['scores']))
if __name__=='__main__':unittest.main()
