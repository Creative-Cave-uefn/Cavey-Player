"""Run without Deezer account, network, or third-party dependencies."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'assets' / 'deezer_bridge.py'
spec = importlib.util.spec_from_file_location('deezer_bridge', SCRIPT)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class FakeDeezer:
    TYPE_TRACK = 'track'
    TYPE_ALBUM = 'album'

    def deezer_search(self, query, kind):
        return [{'id': '20', 'artist': 'Wrong', 'title': 'Song'},
                {'id': '12', 'artist': 'Demo Artist', 'title': 'Demo Song'}]

    def get_song_infos_from_deezer_website(self, kind, number):
        if kind == 'album':
            return [self.get_song_infos_from_deezer_website('track', str(x)) for x in (12, 13)]
        return {'SNG_ID': str(number), 'ART_NAME': 'Demo Artist', 'SNG_TITLE': f'Demo Song {number}'}

    def parse_deezer_playlist(self, number):
        return 'Demo playlist', [self.get_song_infos_from_deezer_website('track', '12')]

    def get_file_extension(self):
        return 'mp3'

    def download_song(self, song, filename):
        Path(filename).write_bytes(b'x' * 2048)


class BridgeTests(unittest.TestCase):
    def test_allowed_links_and_search(self):
        self.assertEqual(bridge.parse_input('Demo Artist — Demo Song'), ('search', ('Demo Artist', 'Demo Song')))
        self.assertEqual(bridge.parse_input('https://www.deezer.com/en/track/123?x=1'), ('track', '123'))
        self.assertEqual(bridge.parse_input('https://deezer.com/album/42'), ('album', '42'))
        self.assertEqual(bridge.parse_input('https://www.deezer.com/playlist/2'), ('playlist', '2'))
        for input_ in ('Song', 'https://deezer.com/', 'https://deezer.com.evil.com/track/3',
                       'https://soundcloud.com/user/song', 'ftp://deezer.com/track/12',
                       'https://deezer.com/track/not-a-number'):
            with self.subTest(input_=input_), self.assertRaises(ValueError):
                bridge.parse_input(input_)

    def test_auth_and_filename(self):
        with tempfile.TemporaryDirectory() as d:
            config = Path(d) / 'deezer.ini'
            config.write_text('[deezer]\narl = ' + 'a' * 200 + '\nquality = flac\n')
            self.assertEqual(bridge.load_auth(str(config)), ('a'*200, 'flac'))
            config.write_text('[deezer]\narl = PASTE_ARL_COOKIE_HERE\n')
            with self.assertRaises(ValueError):
                bridge.load_auth(str(config))
        self.assertNotIn('/', bridge.safe_filename('../demo:track<>'))

    def test_strict_match(self):
        self.assertEqual(bridge.choose_exact(FakeDeezer().deezer_search('', 'track'), 'demo artist', 'Demo Song')['id'], '12')
        with self.assertRaises(RuntimeError):
            bridge.choose_exact(FakeDeezer().deezer_search('', 'track'), 'Missing', 'Song')

    def test_search_and_album_use_correct_backend(self):
        fake = FakeDeezer()
        with tempfile.TemporaryDirectory() as d:
            auth = Path(d) / 'auth.ini'
            auth.write_text('[deezer]\narl=' + 'a'*200 + '\nquality=mp3\n')
            out = Path(d) / 'out'
            with patch.object(bridge, '_load_backend', return_value=fake):
                self.assertEqual(bridge.download(str(auth), 'Demo Artist - Demo Song', str(out)), 0)
                self.assertEqual(len(list(out.glob('*.mp3'))), 1)
                self.assertEqual(bridge.download(str(auth), 'https://deezer.com/album/9', str(out)), 0)
                self.assertGreaterEqual(len(list(out.glob('*.mp3'))), 2)


if __name__ == '__main__':
    unittest.main(verbosity=2)
