import 'dart:convert';
import 'dart:io';

import 'package:cave_player/core/dl/zotify_install.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Installer script parses with spaces, Cyrillic and quotes in user path', () async {
    final dir = await Directory.systemTemp.createTemp('zotify-script');
    try {
      final file = File('${dir.path}${Platform.pathSeparator}install.ps1');
      final script = ZotifyInstall.scriptFor(r"C:\Users\Олег's Name\tools", r"C:\Users\Олег's Name\tools\Scripts\zotify.exe");
      await file.writeAsString('\uFEFF$script', encoding: utf8);
      final quotedPath = "'${file.path.replaceAll("'", "''")}'";
      final check = r'$tokens=$null; $errors=$null; [System.Management.Automation.Language.Parser]::ParseFile(PATH, [ref]$tokens, [ref]$errors) | Out-Null; if ($errors.Count) { $errors | Out-String | Write-Output; exit 1 }'
          .replaceAll('PATH', quotedPath);
      final encoded = base64.encode([for (final c in check.codeUnits) ...[c & 255, c >> 8]]);
      final result = await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);
}
