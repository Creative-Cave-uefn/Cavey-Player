import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';

import 'log.dart';
import 'store.dart';

/// Настройки уведомлений и автозапуска. Лежат в `settings.view` (только на этом компьютере).
extension NotifyPrefs on Settings {
  /// Показывать уведомления вообще
  bool get notifyOn => viewOf('ntf.on', '1') == '1';

  /// Звук при новом уведомлении
  bool get notifySound => viewOf('ntf.sound', '1') == '1';

  /// Громкость звука уведомления, 0…100
  int get notifyVolume => viewNum('ntf.vol', 60).round().clamp(0, 100).toInt();

  /// Уведомление Windows, когда окно спрятано, свёрнуто или не в фокусе
  bool get notifySystem => viewOf('ntf.sys', '1') == '1';

  /// Свой звук: путь к файлу; пусто — встроенный мягкий сигнал
  String get notifyFile => viewOf('ntf.file', '');

  /// Автозапуск с Windows: off, show (с открытым окном) или tray (сразу в трей)
  String get autostartMode {
    final v = viewOf('autostart', 'off');
    return v == 'show' || v == 'tray' ? v : 'off';
  }
}

/// Мягкий двухнотный сигнал «динь-дин», собранный в коде: 44,1 кГц, 16 бит, моно. Без файлов в сборке
Uint8List buildChimeWav() {
  const rate = 44100;
  const seconds = 0.9;
  final n = (rate * seconds).round();
  final samples = Float64List(n);
  // Две ноты (ми и ля третьей октавы выше): вторая чуть позже. У каждой мягкая атака и долгое затухание
  void note(double freq, double startSec, double amp) {
    final start = (startSec * rate).round();
    for (var i = start; i < n; i++) {
      final t = (i - start) / rate;
      final attack = math.min(1.0, t / 0.012);
      final decay = math.exp(-t * 6.5);
      final v = math.sin(2 * math.pi * freq * t) + 0.25 * math.sin(2 * math.pi * freq * 2 * t) * math.exp(-t * 10);
      samples[i] += amp * attack * decay * v;
    }
  }

  note(659.25, 0.0, 0.5);
  note(880.0, 0.14, 0.45);
  final data = ByteData(44 + n * 2);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, 1, Endian.little); // моно
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    final v = (samples[i] * 0.6).clamp(-1.0, 1.0);
    data.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Громкость звука уведомления (проценты ползунка) → громкость libmpv: у него шкала кубическая, поэтому корень
double notifyMpvVolume(int percent) => 100 * math.sqrt(percent.clamp(0, 100) / 100);

/// Проигрывает звук уведомления отдельным проигрывателем, не мешая музыке
class NotifySound {
  static Player? _player;
  static File? _chime;

  static Future<String> _defaultPath() async {
    var f = _chime;
    if (f == null || !f.existsSync()) {
      f = File('${Directory.systemTemp.path}${Platform.pathSeparator}cavey_chime.wav');
      await f.writeAsBytes(buildChimeWav(), flush: true);
      _chime = f;
    }
    return f.path;
  }

  /// Играет сигнал с настройками [s]. [force] — игнорировать выключатель звука (кнопка «Прослушать»)
  static Future<void> play(Settings s, {bool force = false}) async {
    if (!force && (!s.notifyOn || !s.notifySound)) return;
    final vol = s.notifyVolume;
    if (vol <= 0) return;
    try {
      final custom = s.notifyFile;
      final path = custom.isNotEmpty && File(custom).existsSync() ? custom : await _defaultPath();
      final p = _player ??= Player();
      await p.setVolume(notifyMpvVolume(vol));
      await p.open(Media(path), play: true);
    } catch (e) {
      AppLog.warn('Звук уведомления не проигрался', e);
    }
  }
}
