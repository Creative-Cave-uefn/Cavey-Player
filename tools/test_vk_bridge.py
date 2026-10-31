"""Pure offline tests using a fake VKpyMusic; no real VK login or download."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

SCRIPT = Path(__file__).resolve().parent.parent / 'assets' / 'vk_bridge.py'
spec = importlib.util.spec_from_file_location('vk_bridge', SCRIPT)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

class FakeSong:
    artist = 'Test Artist'
    title = 'Test Track'
    duration = 185
    owner_id = '-123'
    track_id = '456'

class FakeService:
    def search_songs_by_text(self, query, count=3):
        return [FakeSong()]

    def get_songs_by_id(self, ids):
        return [FakeSong()] if ids == ['-123_456'] else []

    def get_songs_by_playlist_id(self, owner, playlist, key, count, offset):
        return [FakeSong()] if offset == 0 else []

    def save_music(self, song, overwrite=False):
        folder = Path('Music')
        folder.mkdir(exist_ok=True)
        file = folder / 'example.mp3'
        file.write_bytes(b'ID3' + b'\0' * 128)
        return str(file)

class VkBridgeTest(unittest.TestCase):
    def test_auth_failure_messages_are_specific(self):
        def log_with(*lines):
            log = bridge._AuthLog()
            log.lines.extend(lines)
            return log
        self.assertIn('ограничил', bridge.auth_failure_message(log_with('Password bruteforce attempt!')))
        self.assertIn('логин или пароль', bridge.auth_failure_message(log_with('Login or password is invalid!')))
        self.assertIn('Не удалось войти', bridge.auth_failure_message(log_with()))

    def test_parse_valid_input(self):
        self.assertEqual(bridge.parse_input('Test Artist - Test Track'), ('search', ('Test Artist', 'Test Track')))
        self.assertEqual(bridge.parse_input('https://vk.com/audio-123_456'), ('audio', ['-123_456']))
        self.assertEqual(bridge.parse_input('https://vk.com/music/playlist/-123_456_abc'), ('playlist', (-123, 456, 'abc')))

    def test_reject_wrong_host_and_missing_artist(self):
        for input in ('Song', 'https://vk.com.evil.test/audio-123_456',
                      'https://vk.com/music/playlist/abc', 'https://youtube.com/watch?v=3'):
            with self.assertRaises(ValueError, msg=input):
                bridge.parse_input(input)

    def test_exact_match(self):
        self.assertTrue(bridge.song_matches(FakeSong(), 'test artist', 'test track'))
        self.assertFalse(bridge.song_matches(FakeSong(), 'Other artist', 'test track'))
        self.assertFalse(bridge.song_matches(FakeSong(), 'test artist', 'test track (live)'))

    def test_end_to_end_fake_download(self):
        with tempfile.TemporaryDirectory() as root:
            class Patched:
                @staticmethod
                def parse_config(_):
                    return FakeService()
            sys.modules['vkpymusic'] = type(sys)('vkpymusic')
            sys.modules['vkpymusic'].Service = Patched
            original = Path.cwd()
            try:
                out = Path(root)
                (out / 'vk_auth.ini').write_text('[VK]\n', encoding='utf-8')
                import os
                os.chdir(out)
                bridge.download(out / 'vk_auth.ini', out, 'Test Artist - Test Track')
                files = list(out.glob('*.mp3'))
                self.assertEqual(len(files), 1)
                self.assertGreater(files[0].stat().st_size, 0)
            finally:
                import os
                os.chdir(original)
                del sys.modules['vkpymusic']

if __name__ == '__main__':
    unittest.main()
