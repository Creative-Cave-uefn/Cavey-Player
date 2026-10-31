import 'dart:convert';
import 'dart:io';

import 'package:cave_player/core/dl/zotify_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Browser login only replaces credentials after successful session creation', () async {
    final dir = await Directory.systemTemp.createTemp('oauth-test');
    final destination = File('${dir.path}/credentials.json');
    const wrapper = r'''
import json
import sys
import types
from pathlib import Path

source, target, fail = sys.argv[1:]
class Config:
    def set_cache_enabled(self, value): return self
    def set_stored_credential_file(self, path): self.path = path; return self
    def build(self): return self
class Builder:
    def __init__(self, conf): self.conf = conf
    def oauth(self, callback):
        callback('https://accounts.spotify.com/authorize?test=1')
        return self
    def create(self):
        if fail == 'yes': raise RuntimeError('denied')
        Path(self.conf.path).write_text(json.dumps({'username': 'example', 'credentials': 'opaque'}))
        return types.SimpleNamespace(close=lambda: None)
session = types.SimpleNamespace(Configuration=types.SimpleNamespace(Builder=Config), Builder=Builder)
core = types.ModuleType('librespot.core')
core.Session = session
sys.modules['librespot'] = types.ModuleType('librespot')
sys.modules['librespot.core'] = core
sys.argv = ['login', target]
exec(source, {'__name__': '__main__'})
''';
    try {
      await destination.writeAsString('old session');
      final failed = await Process.run('python', ['-c', wrapper, ZotifyAuth.script, destination.path, 'yes']);
      expect(failed.exitCode, isNot(0));
      expect(await destination.readAsString(), 'old session');
      final ok = await Process.run('python', ['-c', wrapper, ZotifyAuth.script, destination.path, 'no']);
      expect(ok.exitCode, 0, reason: '${ok.stdout}\n${ok.stderr}');
      expect('${ok.stdout}', contains('CAVE_AUTH_URL https://accounts.spotify.com/authorize'));
      expect('${ok.stdout}', contains('CAVE_AUTH_OK'));
      expect('${ok.stdout}', isNot(contains('opaque')));
      expect(jsonDecode(await destination.readAsString())['username'], 'example');
      expect(await File('${destination.path}.bak').readAsString(), 'old session');
    } finally { await dir.delete(recursive: true); }
  }, skip: !Platform.isWindows);
}
