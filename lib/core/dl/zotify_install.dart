import 'dart:convert';
import 'dart:io';

import 'tools.dart';

/// Installs in the application's tools folder; credentials remain with Zotify.
class ZotifyInstall {
  static Future<String>? _running;
  static Future<String> install(Tools tools, void Function(String) log) =>
      _running ??= _install(tools, log).whenComplete(() => _running = null);

  static Future<String> _install(Tools tools, void Function(String) log) async {
    if (!Platform.isWindows) throw Exception('Автоустановка пока доступна только в Windows');
    final root = Directory('${tools.dir.path}${Platform.pathSeparator}zotify-env');
    final exe = File('${root.path}${Platform.pathSeparator}Scripts${Platform.pathSeparator}zotify.exe');
    log('Подготавливаю FFmpeg…');
    await tools.ensure(log);
    final script = scriptFor(root.path, exe.path);
    final bytes = <int>[];
    for (final c in script.codeUnits) {
      bytes.addAll([c & 255, c >> 8]);
    }
    final output = await Tools.run('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', base64.encode(bytes),
    ], onLine: log);
    if (!output.contains('CAVE_ZOTIFY_INSTALL_OK') || !await exe.exists()) {
      throw Exception('Не удалось установить Zotify. Подробности в журнале ниже. Может потребоваться App Installer (winget) из Microsoft Store.');
    }
    return exe.path;
  }

  static String scriptFor(String rootPath, String executable) {
    // Data paths enter PowerShell only as single-quoted literals.
    String quote(String value) => "'${value.replaceAll("'", "''")}'";
    return r'''
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function Run-Checked($program, $arguments) {
  & $program @arguments
  if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $program" }
}
function Find-Python {
  $candidates = @(
    "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
    "$env:ProgramFiles\Python311\python.exe"
  )
  foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
  return $null
}
$python = Find-Python
if (-not $python) {
  Write-Output 'Installing Python 3.11...'
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget unavailable. Install App Installer from Microsoft Store and retry.'
  }
  Run-Checked 'winget' @('install', '--id', 'Python.Python.3.11', '--exact', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements')
  $python = Find-Python
  if (-not $python) { throw 'Python 3.11 not found after installation' }
}
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git -and -not (Test-Path "$env:ProgramFiles\Git\cmd\git.exe")) {
  Write-Output 'Installing Git...'
  Run-Checked 'winget' @('install', '--id', 'Git.Git', '--exact', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements')
}
$env:PATH = "$env:ProgramFiles\Git\cmd;$env:LOCALAPPDATA\Programs\Git\cmd;$env:PATH"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git not found; restart Windows and retry' }
Write-Output 'Creating isolated Python environment...'
Run-Checked $python @('-m', 'venv', ROOT)
Write-Output 'Installing Zotify...'
Run-Checked PIP @('install', '--upgrade', 'pip')
Run-Checked PIP @('install', 'https://get.zotify.xyz')
Run-Checked EXE @('--help')
Write-Output 'CAVE_ZOTIFY_INSTALL_OK'
'''
        .replaceAll('ROOT', quote(rootPath))
        .replaceAll('PIP', quote('${rootPath}\\Scripts\\pip.exe'))
        .replaceAll('EXE', quote(executable));
  }

}
