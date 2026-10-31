import 'dart:convert';
import 'dart:io';

import 'package:cave_player/core/dl/zotify_install.dart';
import 'package:cave_player/core/dl/winproc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Installer script parses with spaces, Cyrillic and quotes in user path', () async {
    final dir = await Directory.systemTemp.createTemp('zotify-script');
    try {
      final file = File('${dir.path}${Platform.pathSeparator}install.ps1');
      final script = ZotifyInstall.scriptFor(r"C:\Users\Олег's Name\PIP EXE ROOT\tools", r"C:\Users\Олег's Name\PIP EXE ROOT\tools\Scripts\zotify.exe");
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
  test('Hidden PowerShell launch captures stdout, stderr and exit code', () async {
    const script = "Write-Output 'CAVE_LAUNCH_OK'; [Console]::Error.WriteLine('CAVE_STDERR'); exit 7";
    final encoded = base64.encode([for (final c in script.codeUnits) ...[c & 255, c >> 8]]);
    final lines = <String>[];
    final code = await WinProc.run(ZotifyInstall.powershellExecutable,
        ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded], lines.add);
    expect(code, 7);
    expect(lines, contains('CAVE_LAUNCH_OK'));
    expect(lines, contains('CAVE_STDERR'));
  }, skip: !Platform.isWindows);
  test('Failed process launch reports a Windows error rather than empty output', () async {
    final lines = <String>[];
    final code = await WinProc.run(r'C:\\cave-nonexistent-directory\\missing.exe', [], lines.add);
    expect(code, -1);
    expect(lines.join(), contains('Windows error'));
  }, skip: !Platform.isWindows);

}
