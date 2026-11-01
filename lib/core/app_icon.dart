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

  /// Меняет значок в самом Cave Player.exe после выхода программы: ждёт, пока процесс закроется,
  /// записывает значок в файл, чистит кэш значков и перезапускает проводник. [relaunch] — открыть программу снова
  static Future<bool> patchExeAfterExit(String ico, {required bool relaunch}) async {
    if (!Platform.isWindows) return false;
    try {
      final exe = Platform.resolvedExecutable;
      final script = File('${Directory.systemTemp.path}\\cavey-icon-${DateTime.now().millisecondsSinceEpoch}.ps1');
      await script.writeAsString(_script, flush: true);
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
        ],
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (e) {
      AppLog.warn('Значок файла программы: не получилось запустить замену', e);
      return false;
    }
  }

  // Ресурсы Flutter-приложения: группа значков 101 (IDI_APP_ICON), язык English (US).
  // PNG внутри ресурса значка Windows понимает начиная с Vista
  static const _script = r'''
param([int]$ProcId, [string]$Exe, [string]$Ico, [int]$Relaunch)
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP 'cavey-icon.log'
try {
  try { Wait-Process -Id $ProcId -Timeout 30 -ErrorAction SilentlyContinue } catch {}
  Start-Sleep -Milliseconds 400
  Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
public static class CaveyIcon {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern IntPtr BeginUpdateResource(string file, bool deleteExisting);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool UpdateResource(IntPtr h, IntPtr type, IntPtr name, ushort lang, byte[] data, uint size);
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool EndUpdateResource(IntPtr h, bool discard);
  public static void Apply(string exe, string ico) {
    byte[] b = File.ReadAllBytes(ico);
    int count = BitConverter.ToUInt16(b, 4);
    IntPtr h = BeginUpdateResource(exe, false);
    if (h == IntPtr.Zero) throw new Exception("BeginUpdateResource " + Marshal.GetLastWin32Error());
    MemoryStream grp = new MemoryStream();
    BinaryWriter w = new BinaryWriter(grp);
    w.Write((ushort)0); w.Write((ushort)1); w.Write((ushort)count);
    for (int i = 0; i < count; i++) {
      int o = 6 + i * 16;
      int size = BitConverter.ToInt32(b, o + 8);
      int off = BitConverter.ToInt32(b, o + 12);
      byte[] img = new byte[size];
      Array.Copy(b, off, img, 0, size);
      if (!UpdateResource(h, (IntPtr)3, (IntPtr)(i + 1), 1033, img, (uint)size)) {
        EndUpdateResource(h, true);
        throw new Exception("UpdateResource icon " + Marshal.GetLastWin32Error());
      }
      w.Write(b, o, 12);
      w.Write((ushort)(i + 1));
    }
    byte[] g = grp.ToArray();
    if (!UpdateResource(h, (IntPtr)14, (IntPtr)101, 1033, g, (uint)g.Length)) {
      EndUpdateResource(h, true);
      throw new Exception("UpdateResource group " + Marshal.GetLastWin32Error());
    }
    if (!EndUpdateResource(h, false)) throw new Exception("EndUpdateResource " + Marshal.GetLastWin32Error());
  }
}
"@
  [CaveyIcon]::Apply($Exe, $Ico)
  # Refresh the icon cache and restart Explorer, otherwise the old icon stays until reboot
  try { Start-Process -FilePath 'ie4uinit.exe' -ArgumentList '-show' -WindowStyle Hidden -Wait } catch {}
  try { Start-Process -FilePath 'ie4uinit.exe' -ArgumentList '-ClearIconCache' -WindowStyle Hidden -Wait } catch {}
  Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
  "$(Get-Date -Format s) ok $Exe" | Out-File -FilePath $log -Append -Encoding utf8
} catch {
  "$(Get-Date -Format s) error $($_.Exception.Message)" | Out-File -FilePath $log -Append -Encoding utf8
}
if ($Relaunch -eq 1) { Start-Process -FilePath $Exe }
Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
''';
}
