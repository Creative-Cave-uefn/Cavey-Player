// Значок Cavey в цвете акцента: в трее и у окна меняется сразу, а значок самого файла Cave Player.exe
// (в проводнике, на ярлыках, на панели задач у закреплённого) — отдельным шагом, когда программа закрыта:
// файл, который работает, Windows менять не даёт.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;

import 'log.dart';

/// Яркость жёлтой метки на исходном значке: от неё отсчитываем оттенки нового цвета
const _baseValue = 239 / 255;

/// Размеры картинок внутри .ico
const iconSizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];

/// Перекрашивает цветную метку значка (тёмный фон не трогает). [argb] — цвет акцента
img.Image recolorIcon(img.Image src, int argb) {
  final tr = (argb >> 16) & 0xFF, tg = (argb >> 8) & 0xFF, tb = argb & 0xFF;
  final out = src.clone();
  for (final p in out) {
    if (p.a == 0) continue;
    final r = p.r.toDouble(), g = p.g.toDouble(), b = p.b.toDouble();
    final mx = [r, g, b].reduce((a, c) => a > c ? a : c);
    final mn = [r, g, b].reduce((a, c) => a < c ? a : c);
    if (mx <= 0) continue;
    final sat = (mx - mn) / mx;
    // Насколько пиксель — часть цветной метки: серый фон (насыщенность ~0) остаётся как был
    final w = ((sat - 0.25) / 0.35).clamp(0.0, 1.0);
    if (w == 0) continue;
    final k = (mx / 255) / _baseValue;
    double mix(double from, int to) => from + ((to * k).clamp(0, 255) - from) * w;
    p
      ..r = mix(r, tr).round()
      ..g = mix(g, tg).round()
      ..b = mix(b, tb).round();
  }
  return out;
}

/// Собирает .ico из PNG-картинок (так Windows умеет с Vista): заголовок, записи о размерах, сами PNG
Uint8List buildIco(List<(int, Uint8List)> images) {
  final head = BytesBuilder();
  final data = BytesBuilder();
  var offset = 6 + 16 * images.length;
  void u16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  u16(head, 0);
  u16(head, 1);
  u16(head, images.length);
  for (final (size, png) in images) {
    head.add([size >= 256 ? 0 : size, size >= 256 ? 0 : size, 0, 0]);
    u16(head, 1); // плоскости
    u16(head, 32); // бит на пиксель
    u32(head, png.length);
    u32(head, offset);
    offset += png.length;
    data.add(png);
  }
  return Uint8List.fromList([...head.toBytes(), ...data.toBytes()]);
}

/// Готовит .ico в цвете [argb] из картинки значка [png] (в отдельном потоке — это пара сотен миллисекунд)
Uint8List accentIco((Uint8List, int) args) {
  final src = img.decodePng(args.$1);
  if (src == null) throw Exception('Значок не прочитался');
  final big = recolorIcon(src, args.$2);
  return buildIco([
    for (final s in iconSizes)
      (s, Uint8List.fromList(img.encodePng(s == big.width ? big : img.copyResize(big, width: s, height: s, interpolation: img.Interpolation.average))))
  ]);
}

/// Логотип (PNG) с меткой в цвете [argb]: для значка в боковой панели
Uint8List recolorLogoPng((Uint8List, int) args) {
  final src = img.decodePng(args.$1);
  if (src == null) throw Exception('Логотип не прочитался');
  return Uint8List.fromList(img.encodePng(recolorIcon(src, args.$2)));
}

class AppIcon {
  /// Значок по умолчанию из сборки
  static const defaultIcon = 'assets/app_icon.ico';

  /// Путь к .ico в цвете акцента (готовит, если ещё нет). null для стандартного цвета — берётся значок из сборки
  static Future<String?> prepare(Directory dir, int argb, {required bool isDefault}) async {
    if (isDefault) return null;
    final hex = (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
    final f = File('${dir.path}${Platform.pathSeparator}app_icon_$hex.ico');
    if (await f.exists() && await f.length() > 0) return f.path;
    final png = (await rootBundle.load('assets/logo.png')).buffer.asUint8List();
    final ico = await compute(accentIco, (png, argb));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(ico, flush: true);
    return f.path;
  }

  /// Значок у окна (и на панели задач у открытого окна): WM_SETICON с картинками из .ico.
  /// [path] — полный путь или путь ассета сборки
  static Future<void> applyToWindow(String path) async {
    if (!Platform.isWindows) return;
    try {
      final full = File(path).isAbsolute ? path : '${File(Platform.resolvedExecutable).parent.path}\\data\\flutter_assets\\$path';
      final user32 = DynamicLibrary.open('user32.dll');
      final find = user32.lookupFunction<IntPtr Function(Pointer<Utf16>, Pointer<Utf16>), int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');
      final load = user32.lookupFunction<IntPtr Function(IntPtr, Pointer<Utf16>, Uint32, Int32, Int32, Uint32),
          int Function(int, Pointer<Utf16>, int, int, int, int)>('LoadImageW');
      final send = user32.lookupFunction<IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr), int Function(int, int, int, int)>('SendMessageW');
      final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
      final file = full.toNativeUtf16();
      try {
        final hwnd = find(cls, nullptr);
        if (hwnd == 0) return;
        const imageIcon = 1, loadFromFile = 0x10, wmSetIcon = 0x80;
        final big = load(0, file, imageIcon, 32, 32, loadFromFile);
        final small = load(0, file, imageIcon, 16, 16, loadFromFile);
        if (big != 0) send(hwnd, wmSetIcon, 1, big);
        if (small != 0) send(hwnd, wmSetIcon, 0, small);
      } finally {
        malloc.free(cls);
        malloc.free(file);
      }
    } catch (e) {
      AppLog.warn('Значок окна не сменился', e);
    }
  }

  /// Полный путь к стандартному значку из сборки (для возврата значка файла к обычному)
  static String bundledIco() => '${File(Platform.resolvedExecutable).parent.path}\\data\\flutter_assets\\assets\\app_icon.ico';

  /// Куда скрипт замены кладёт итог («ok|метка» или «error|причина»): при следующем запуске приложение
  /// по нему понимает, получилось ли, а не считает значок сменённым только потому, что скрипт запустился
  static Future<(bool, String)?> takeResult(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      final text = (await f.readAsString()).replaceAll('﻿', '').trim();
      await f.delete();
      final cut = text.indexOf('|');
      if (cut < 0) return (false, text);
      return (text.substring(0, cut) == 'ok', text.substring(cut + 1));
    } catch (e) {
      AppLog.warn('Итог замены значка не прочитался', e);
      return null;
    }
  }

  static String _tempScript(String name) => '${Directory.systemTemp.path}\\cavey-$name-${DateTime.now().millisecondsSinceEpoch}.ps1';

  /// Меняет значок в самом Cave Player.exe после выхода программы: ждёт, пока процесс закроется,
  /// записывает значок в файл, обновляет ярлыки, чистит кэш значков и перезапускает проводник.
  /// [relaunch] — открыть программу снова. [token] и [resultFile] — см. [takeResult].
  /// Каждый шаг пишется в %TEMP%\cavey-icon.log
  static Future<bool> patchExeAfterExit(String ico, {required bool relaunch, required String token, required String resultFile}) async {
    if (!Platform.isWindows) return false;
    try {
      final exe = Platform.resolvedExecutable;
      final script = File(_tempScript('icon'));
      await script.writeAsString(_script, flush: true);
      try {
        final old = File(resultFile);
        if (await old.exists()) await old.delete();
      } catch (_) {}
      AppLog.info('Значок файла программы: запускаю замену ($token) для $exe');
      await Process.start(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          script.path,
          '-ProcId',
          '$pid',
          '-Exe',
          exe,
          '-Ico',
          ico,
          '-Relaunch',
          relaunch ? '1' : '0',
          '-Token',
          token,
          '-Result',
          resultFile,
        ],
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (e) {
      AppLog.warn('Значок файла программы: не получилось запустить замену', e);
      return false;
    }
  }

  /// Ярлыки Cavey (меню «Пуск», рабочий стол, закреплённый на панели задач) сразу получают значок [ico]
  /// (null — вернуть значок из программы). Работает, пока программа открыта: значок ярлыка не лежит в exe
  static Future<void> refreshShortcuts(String? ico) async {
    if (!Platform.isWindows) return;
    try {
      final script = File(_tempScript('lnk'));
      await script.writeAsString(_shortcutsOnly, flush: true);
      try {
        final r = await Process.run('powershell.exe', [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          script.path,
          '-Exe',
          Platform.resolvedExecutable,
          '-Ico',
          ico ?? '',
        ]).timeout(const Duration(seconds: 25));
        if (r.exitCode != 0) AppLog.warn('Значки ярлыков: powershell вернул ${r.exitCode}', '${r.stderr}'.trim());
      } finally {
        try {
          await script.delete();
        } catch (_) {}
      }
    } catch (e) {
      AppLog.warn('Значки ярлыков не обновились', e);
    }
  }

  // В скриптах только ASCII: PowerShell 5 читает файл без BOM в системной кодовой странице

  // Обновление значка у ярлыков, которые ведут на наш exe
  static const _shortcutsFn = r'''
function Update-CaveyShortcuts([string]$Exe, [string]$Loc) {
  $dirs = @(
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
    [Environment]::GetFolderPath('Desktop'),
    [Environment]::GetFolderPath('CommonDesktopDirectory'),
    (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'),
    (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\StartMenu')
  )
  $sh = New-Object -ComObject WScript.Shell
  foreach ($d in $dirs) {
    if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
    Get-ChildItem -LiteralPath $d -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
      try {
        $l = $sh.CreateShortcut($_.FullName)
        if ($l.TargetPath -ieq $Exe) {
          $l.IconLocation = $Loc
          $l.Save()
          Log "shortcut updated: $($_.FullName)"
        }
      } catch { Log "shortcut $($_.FullName): $($_.Exception.Message)" }
    }
  }
}
''';

  static const _logFn = r'''
$log = Join-Path $env:TEMP 'cavey-icon.log'
function Log([string]$m) { try { "$(Get-Date -Format s) $m" | Out-File -FilePath $log -Append -Encoding utf8 } catch {} }
''';

  static const _shortcutsOnly = r'''
param([string]$Exe, [string]$Ico)
$ErrorActionPreference = 'Stop'
''' +
      _logFn +
      _shortcutsFn +
      r'''
try {
  $loc = "$Exe,0"
  if ($Ico -and (Test-Path -LiteralPath $Ico)) { $loc = "$Ico,0" }
  Log "shortcuts: icon location $loc"
  Update-CaveyShortcuts $Exe $loc
} catch { Log "shortcuts error $($_.Exception.Message)" }
''';

  // Ресурсы Flutter-приложения: группа значков 101 (IDI_APP_ICON). Язык ресурса берём у существующего,
  // старые значки и группы удаляем: иначе Windows может выбрать прежний ресурс другого языка.
  // PNG внутри ресурса значка Windows понимает начиная с Vista
  static const _script = r'''
param([int]$ProcId, [string]$Exe, [string]$Ico, [int]$Relaunch, [string]$Token, [string]$Result)
$ErrorActionPreference = 'Stop'
''' +
      _logFn +
      _shortcutsFn +
      r'''
$ok = $false
$msg = ''
try {
  Log "start pid=$ProcId exe=$Exe ico=$Ico token=$Token relaunch=$Relaunch"
  if (-not (Test-Path -LiteralPath $Exe)) { throw "exe not found" }
  if (-not (Test-Path -LiteralPath $Ico)) { throw "ico not found" }
  try { Wait-Process -Id $ProcId -Timeout 40 -ErrorAction SilentlyContinue } catch {}
  if (Get-Process -Id $ProcId -ErrorAction SilentlyContinue) { Log "process is still running after 40 s" } else { Log "process exited" }
  Start-Sleep -Milliseconds 600
  Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class CaveyIcon {
  delegate bool NamesProc(IntPtr m, IntPtr type, IntPtr name, IntPtr param);
  delegate bool LangsProc(IntPtr m, IntPtr type, IntPtr name, ushort lang, IntPtr param);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern IntPtr LoadLibraryEx(string file, IntPtr h, uint flags);
  [DllImport("kernel32.dll")]
  static extern bool FreeLibrary(IntPtr m);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool EnumResourceNames(IntPtr m, IntPtr type, NamesProc p, IntPtr param);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool EnumResourceLanguages(IntPtr m, IntPtr type, IntPtr name, LangsProc p, IntPtr param);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern IntPtr BeginUpdateResource(string file, bool deleteExisting);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool UpdateResource(IntPtr h, IntPtr type, IntPtr name, ushort lang, byte[] data, uint size);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool EndUpdateResource(IntPtr h, bool discard);
  [DllImport("shell32.dll")]
  static extern void SHChangeNotify(int ev, uint flags, IntPtr a, IntPtr b);

  public static List<KeyValuePair<int, ushort>> Find(string exe, int type) {
    List<KeyValuePair<int, ushort>> res = new List<KeyValuePair<int, ushort>>();
    IntPtr m = LoadLibraryEx(exe, IntPtr.Zero, 0x2);
    if (m == IntPtr.Zero) return res;
    try {
      List<int> names = new List<int>();
      NamesProc np = delegate(IntPtr a, IntPtr t, IntPtr n, IntPtr p) { if (((long)n >> 16) == 0) names.Add((int)n); return true; };
      EnumResourceNames(m, (IntPtr)type, np, IntPtr.Zero);
      foreach (int id in names) {
        int cur = id;
        LangsProc lp = delegate(IntPtr a, IntPtr t, IntPtr n, ushort l, IntPtr p) { res.Add(new KeyValuePair<int, ushort>(cur, l)); return true; };
        EnumResourceLanguages(m, (IntPtr)type, (IntPtr)id, lp, IntPtr.Zero);
      }
    } finally { FreeLibrary(m); }
    return res;
  }

  public static void Notify() { SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero); }

  public static string Apply(string exe, string ico) {
    byte[] b = File.ReadAllBytes(ico);
    int count = BitConverter.ToUInt16(b, 4);
    List<KeyValuePair<int, ushort>> groups = Find(exe, 14);
    List<KeyValuePair<int, ushort>> icons = Find(exe, 3);
    ushort lang = 1033;
    foreach (KeyValuePair<int, ushort> g in groups) if (g.Key == 101) lang = g.Value;
    IntPtr h = IntPtr.Zero;
    int err = 0;
    for (int i = 0; i < 20; i++) {
      h = BeginUpdateResource(exe, false);
      if (h != IntPtr.Zero) break;
      err = Marshal.GetLastWin32Error();
      System.Threading.Thread.Sleep(500);
    }
    if (h == IntPtr.Zero) throw new Exception("BeginUpdateResource error " + err + " (file is busy or not writable)");
    try {
      foreach (KeyValuePair<int, ushort> o in icons) UpdateResource(h, (IntPtr)3, (IntPtr)o.Key, o.Value, null, 0);
      foreach (KeyValuePair<int, ushort> g in groups) UpdateResource(h, (IntPtr)14, (IntPtr)g.Key, g.Value, null, 0);
      MemoryStream grp = new MemoryStream();
      BinaryWriter w = new BinaryWriter(grp);
      w.Write((ushort)0); w.Write((ushort)1); w.Write((ushort)count);
      for (int i = 0; i < count; i++) {
        int o = 6 + i * 16;
        int size = BitConverter.ToInt32(b, o + 8);
        int off = BitConverter.ToInt32(b, o + 12);
        byte[] img = new byte[size];
        Array.Copy(b, off, img, 0, size);
        if (!UpdateResource(h, (IntPtr)3, (IntPtr)(i + 1), lang, img, (uint)size)) throw new Exception("UpdateResource icon error " + Marshal.GetLastWin32Error());
        w.Write(b, o, 12);
        w.Write((ushort)(i + 1));
      }
      byte[] gd = grp.ToArray();
      if (!UpdateResource(h, (IntPtr)14, (IntPtr)101, lang, gd, (uint)gd.Length)) throw new Exception("UpdateResource group error " + Marshal.GetLastWin32Error());
    } catch {
      EndUpdateResource(h, true);
      throw;
    }
    if (!EndUpdateResource(h, false)) throw new Exception("EndUpdateResource error " + Marshal.GetLastWin32Error());
    List<KeyValuePair<int, ushort>> after = Find(exe, 3);
    return "lang=" + lang + " oldIcons=" + icons.Count + " oldGroups=" + groups.Count + " newIcons=" + after.Count + " wanted=" + count;
  }
}
"@
  Log "helper compiled"
  $r = [CaveyIcon]::Apply($Exe, $Ico)
  Log "resources written: $r"
  (Get-Item -LiteralPath $Exe).LastWriteTime = Get-Date
  $ok = $true
} catch {
  $msg = $_.Exception.Message
  Log "error: $msg"
}
if ($ok) {
  try { Update-CaveyShortcuts $Exe "$Exe,0" } catch { Log "shortcuts: $($_.Exception.Message)" }
  try {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 1200
    Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'IconCache.db') -Force -ErrorAction SilentlyContinue
    $ex = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
    if (Test-Path -LiteralPath $ex) { Get-ChildItem -LiteralPath $ex -Filter 'iconcache_*.db' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Start-Sleep -Seconds 2
    try { Start-Process -FilePath 'ie4uinit.exe' -ArgumentList '-show' -WindowStyle Hidden -Wait } catch {}
    try { [CaveyIcon]::Notify() } catch {}
    Log "icon cache cleared, explorer restarted"
  } catch { Log "explorer: $($_.Exception.Message)" }
}
try {
  $text = if ($ok) { "ok|$Token" } else { "error|$msg" }
  [System.IO.File]::WriteAllText($Result, $text, (New-Object System.Text.UTF8Encoding($false)))
} catch { Log "result file: $($_.Exception.Message)" }
if ($Relaunch -eq 1) { try { Start-Process -FilePath $Exe } catch { Log "relaunch: $($_.Exception.Message)" } }
Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
''';
}
