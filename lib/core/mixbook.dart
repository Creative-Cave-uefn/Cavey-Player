import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'log.dart';

// Ручные настройки переходов: для пары «трек → следующий трек» можно задать свой переход
// (как кнопка «Микс» в Spotify). Пара запоминается независимо от плейлиста: один и тот же переход звучит везде,
// где эти два трека стоят подряд.

/// Как сводить пару треков
enum TransitionMode {
  /// По общим настройкам, автоматически
  auto,

  /// По настройкам, заданным вручную для этой пары
  manual,

  /// Без перехода: первый трек доигрывает, второй начинается следом
  cut,
}

/// Настройки одного перехода. Пустые поля берутся из автоматического плана
class TransitionPref {
  final TransitionMode mode;

  /// 'dj' — по долям, с подгонкой темпа; 'fade' — плавное наложение
  final String style;

  /// Длина: в тактах для 'dj', в секундах для 'fade'
  final int bars;
  final int seconds;

  /// Где в уходящем треке начать переход и с какого места начать следующий, мс. null — автоматически
  final int? outMs;
  final int? inMs;

  /// Подгонять темп следующего трека под уходящий
  final bool sync;

  /// Менять басы местами на середине (только 'dj')
  final bool bass;

  /// Сдвиг долей следующего трека, мс
  final int offsetMs;

  const TransitionPref({
    this.mode = TransitionMode.auto,
    this.style = 'dj',
    this.bars = 8,
    this.seconds = 6,
    this.outMs,
    this.inMs,
    this.sync = true,
    this.bass = true,
    this.offsetMs = 0,
  });

  TransitionPref copyWith({
    TransitionMode? mode,
    String? style,
    int? bars,
    int? seconds,
    Object? outMs = _keep,
    Object? inMs = _keep,
    bool? sync,
    bool? bass,
    int? offsetMs,
  }) =>
      TransitionPref(
        mode: mode ?? this.mode,
        style: style ?? this.style,
        bars: bars ?? this.bars,
        seconds: seconds ?? this.seconds,
        outMs: identical(outMs, _keep) ? this.outMs : outMs as int?,
        inMs: identical(inMs, _keep) ? this.inMs : inMs as int?,
        sync: sync ?? this.sync,
        bass: bass ?? this.bass,
        offsetMs: offsetMs ?? this.offsetMs,
      );

  static const Object _keep = Object();

  Map<String, dynamic> toJson() => {
        'm': mode.name,
        's': style,
        'b': bars,
        'sec': seconds,
        if (outMs != null) 'o': outMs,
        if (inMs != null) 'i': inMs,
        'sy': sync,
        'ba': bass,
        if (offsetMs != 0) 'of': offsetMs,
      };

  static TransitionPref? fromJson(dynamic j) {
    if (j is! Map) return null;
    try {
      final mode = TransitionMode.values.firstWhere((m) => m.name == j['m'], orElse: () => TransitionMode.auto);
      return TransitionPref(
        mode: mode,
        style: j['s'] == 'fade' ? 'fade' : 'dj',
        bars: ((j['b'] as num?)?.toInt() ?? 8).clamp(1, 64).toInt(),
        seconds: ((j['sec'] as num?)?.toInt() ?? 6).clamp(1, 20).toInt(),
        outMs: (j['o'] as num?)?.toInt(),
        inMs: (j['i'] as num?)?.toInt(),
        sync: j['sy'] != false,
        bass: j['ba'] != false,
        offsetMs: ((j['of'] as num?)?.toInt() ?? 0).clamp(-300, 300).toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is TransitionPref &&
      other.mode == mode &&
      other.style == style &&
      other.bars == bars &&
      other.seconds == seconds &&
      other.outMs == outMs &&
      other.inMs == inMs &&
      other.sync == sync &&
      other.bass == bass &&
      other.offsetMs == offsetMs;

  @override
  int get hashCode => Object.hash(mode, style, bars, seconds, outMs, inMs, sync, bass, offsetMs);
}

/// Все ручные переходы. Хранится одним файлом рядом с профилями звука
class MixBook extends ChangeNotifier {
  final File file;
  MixBook(this.file) {
    _load();
  }

  final Map<String, TransitionPref> _prefs = {};
  Timer? _saveTimer;

  static String keyOf(String from, String to) => '$from>$to';

  /// Сколько переходов настроено вручную
  int get count => _prefs.length;

  /// Настройка перехода; null — не менялась (автоматический)
  TransitionPref? get(String from, String to) => _prefs[keyOf(from, to)];

  /// Задаёт переход. Автоматический без отличий от общих настроек не хранится
  void set(String from, String to, TransitionPref pref) {
    if (pref.mode == TransitionMode.auto) {
      remove(from, to);
      return;
    }
    if (_prefs[keyOf(from, to)] == pref) return;
    _prefs[keyOf(from, to)] = pref;
    _changed();
  }

  void remove(String from, String to) {
    if (_prefs.remove(keyOf(from, to)) != null) _changed();
  }

  void _changed() {
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _save);
  }

  void _load() {
    try {
      if (!file.existsSync()) return;
      final j = jsonDecode(file.readAsStringSync());
      if (j is! Map) return;
      for (final e in j.entries) {
        final p = TransitionPref.fromJson(e.value);
        if (p != null) _prefs[e.key as String] = p;
      }
    } catch (e) {
      AppLog.warn('Ручные переходы: не удалось прочитать файл', e);
    }
  }

  void _save() {
    _saveTimer = null;
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode({for (final e in _prefs.entries) e.key: e.value.toJson()}));
    } catch (e) {
      AppLog.warn('Ручные переходы: не удалось сохранить', e);
    }
  }

  /// Записать сразу (перед выходом)
  void flush() {
    if (_saveTimer != null) {
      _saveTimer!.cancel();
      _save();
    }
  }

  @override
  void dispose() {
    flush();
    super.dispose();
  }
}
