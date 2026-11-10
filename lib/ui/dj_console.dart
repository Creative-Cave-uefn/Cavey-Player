import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../app.dart';
import '../core/automix.dart';
import '../core/dj_live_math.dart';
import '../core/models.dart';
import 'theme.dart';

Future<void> showDjConsole(BuildContext context) => showDialog<void>(
  context: context, barrierDismissible: false,
  builder: (_) => const _DjConsole(),
);

/// The ordinary player is paused while this separate, two-deck console runs.
/// No queue edits are performed until the user returns to the ordinary player.
class _DjConsole extends StatefulWidget {
  const _DjConsole();
  @override
  State<_DjConsole> createState() => _DjConsoleState();
}

class _DjConsoleState extends State<_DjConsole> {
  final _decks = [Player(), Player()];
  final _tracks = <Track?>[null, null];
  final _loading = <bool>[false, false];
  final _rates = <double>[1, 1];
  final _bassCut = <bool>[false, false];
  final _cues = <Duration>[Duration.zero, Duration.zero];
  final _preview = <double?>[null, null];
  final _sequence = <int>[0, 0];
  late AppServices _app;
  bool _entered = false, _ready = false, _closing = false;
  double _cross = 0, _master = 0.70;
  String _status = 'Две независимые деки. Обычный плеер будет поставлен на паузу.';
  Timer? _refresh, _gainTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entered) return;
    _entered = true;
    _app = Services.of(context);
    unawaited(_enter());
  }

  Future<void> _enter() async {
    if (_app.player.jamActive?.call() ?? false) {
      _message('Во время совместного прослушивания DJ-режим недоступен.');
      return;
    }
    try {
      final current = _app.player.current;
      final position = _app.player.position.value;
      final next = _app.player.upcoming.firstOrNull;
      await _app.player.pause();
      await Future.wait([_decks[0].setVolume(0), _decks[1].setVolume(0)]);
      if (!mounted) return;
      setState(() => _ready = true);
      _refresh = Timer.periodic(const Duration(milliseconds: 120), (_) {
        if (mounted && !_closing) setState(() {});
      });
      if (current != null) await _load(0, current, start: position);
      if (next != null && mounted) await _load(1, next);
    } catch (e) {
      _message('Не удалось запустить деки: ' + e.toString());
    }
  }

  void _message(String value) {
    if (mounted) setState(() => _status = value);
  }

  MixProfile? _profile(int i) {
    final track = _tracks[i];
    return track == null ? null : _app.player.mixer?.profileCached(track.id);
  }

  Future<void> _load(int i, Track t, {Duration start = Duration.zero}) async {
    if (!_ready || _closing) return;
    final serial = ++_sequence[i];
    setState(() {
      _loading[i] = true;
      _tracks[i] = t;
      _rates[i] = 1;
      _bassCut[i] = false;
      _cues[i] = start;
    });
    try {
      final media = await _app.player.mediaForDj(t);
      if (!mounted || _closing || serial != _sequence[i]) return;
      final p = _decks[i];
      await p.setVolume(0);
      await p.stop();
      await p.setRate(1);
      await p.open(media, play: false);
      try {
        await (p.platform as dynamic).setProperty('af', '');
      } catch (_) {}
      if (start > Duration.zero) await p.seek(start);
      if (mounted && serial == _sequence[i]) {
        _gain();
        _message('Дека ' + (i == 0 ? 'A' : 'B') + ': «' + t.title + '» загружена.');
      }
    } catch (e) {
      _message('Ошибка загрузки «' + t.title + '»: ' + e.toString());
    } finally {
      if (mounted && serial == _sequence[i]) {
        setState(() => _loading[i] = false);
      }
    }
  }

  void _gain() {
    if (_gainTimer != null || _closing) return;
    _gainTimer = Timer(const Duration(milliseconds: 25), () {
      _gainTimer = null;
      if (_closing) return;
      final g = djCrossfaderGains(_cross, master: _master);
      unawaited(Future.wait([
        _decks[0].setVolume(g.$1 * 100),
        _decks[1].setVolume(g.$2 * 100),
      ]).then<void>((_) {}, onError: (Object e) {
        _message('Громкость: ' + e.toString());
      }));
    });
  }

  Future<void> _playPause(int i) async {
    if (_tracks[i] == null || _loading[i]) return;
    try {
      final p = _decks[i];
      if (p.state.playing) { await p.pause(); } else { await p.play(); }
    } catch (e) {
      _message('Воспроизведение: ' + e.toString());
    }
  }

  Future<void> _seek(int i, Duration target) async {
    if (_tracks[i] == null || _loading[i]) return;
    try {
      await _decks[i].seek(target < Duration.zero ? Duration.zero : target);
    } catch (e) {
      _message('Перемотка: ' + e.toString());
    }
  }

  Future<void> _setRate(int i) async {
    if (_tracks[i] == null || _loading[i]) return;
    try {
      await _decks[i].setRate(_rates[i]);
    } catch (e) {
      _message('Темп: ' + e.toString());
    }
  }

  Future<void> _bass(int i, bool enabled) async {
    if (_tracks[i] == null || _loading[i]) return;
    try {
      await (_decks[i].platform as dynamic).setProperty(
        'af', enabled ? 'lavfi=[highpass=f=220]' : '');
      if (mounted) setState(() => _bassCut[i] = enabled);
    } catch (_) {
      _message('Встроенный аудиодвижок не поддерживает этот фильтр.');
    }
  }

  Future<void> _sync(int follower) async {
    if (_tracks[follower] == null || _tracks[1 - follower] == null) return;
    final leader = 1 - follower;
    final a = _profile(leader), b = _profile(follower);
    if (a?.bpm == null || b?.bpm == null) {
      _message('Сначала разберите BPM обоих треков через меню «АвтоDJ».');
      return;
    }
    final rate = djSyncRate(
      leaderBpm: a!.bpm!, leaderRate: _rates[leader],
      followerBpm: b!.bpm!,
    );
    if (rate == null) {
      _message('Разница темпов слишком велика (максимум ±16%).');
      return;
    }
    setState(() => _rates[follower] = rate);
    await _setRate(follower);
    final lh = a.headBeatMs, fh = b.headBeatMs;
    if (lh == null || fh == null) {
      _message('Темп совпадает. Фазу долей настройте кнопками ±20 мс.');
      return;
    }
    final shift = djBeatNudgeMs(
      leaderPositionMs: _decks[leader].state.position.inMilliseconds.toDouble(),
      leaderBeatOriginMs: lh.toDouble(), leaderBpm: a.bpm!,
      followerPositionMs: _decks[follower].state.position.inMilliseconds.toDouble(),
      followerBeatOriginMs: fh.toDouble(), followerBpm: b.bpm!,
    );
    await _seek(follower, _decks[follower].state.position +
        Duration(microseconds: (shift * 1000).round()));
    _message('SYNC: темп и доли выровнены приблизительно. Проверьте на слух.');
  }

  Future<void> _pick(int i) async {
    final tracks = _app.lib.allTracks;
    final selected = await showDialog<Track>(context: context,
      builder: (dialog) {
        String query = '';
        return StatefulBuilder(builder: (context, update) {
          final q = query.trim().toLowerCase();
          final matches = tracks.where((t) => q.isEmpty ||
            t.title.toLowerCase().contains(q) ||
            t.artist.toLowerCase().contains(q)).take(100).toList();
          return AlertDialog(
            title: Text('Загрузить деку ' + (i == 0 ? 'A' : 'B')),
            content: SizedBox(width: 510, height: 440, child: Column(children: [
              TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Поиск трека', prefixIcon: Icon(Icons.search_rounded)),
                onChanged: (v) => update(() => query = v),
              ),
              const SizedBox(height: 8),
              Expanded(child: ListView.builder(
                itemCount: matches.length,
                itemBuilder: (context, n) {
                  final t = matches[n];
                  return ListTile(dense: true,
                    title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.of(context).pop(t));
                },
              )),
            ])),
            actions: [TextButton(
              onPressed: () => Navigator.of(dialog).pop(),
              child: const Text('Отмена'))],
          );
        });
      });
    if (selected != null && mounted) await _load(i, selected);
  }

  Future<void> _exit(bool resume) async {
    if (_closing) return;
    setState(() => _closing = true);
    _refresh?.cancel();
    _gainTimer?.cancel();
    try {
      await Future.wait([_decks[0].stop(), _decks[1].stop()]);
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pop();
    if (resume) unawaited(_app.player.play());
  }

  @override
  void dispose() {
    _closing = true;
    _refresh?.cancel();
    _gainTimer?.cancel();
    for (final p in _decks) { unawaited(p.dispose()); }
    super.dispose();
  }

  String _time(Duration d) {
    final seconds = math.max(0, d.inSeconds);
    return (seconds ~/ 60).toString() + ':' +
      (seconds % 60).toString().padLeft(2, '0');
  }

  Widget _deck(int i) {
    final t = _tracks[i], p = _decks[i], info = _profile(i);
    final pos = p.state.position, duration = p.state.duration;
    final maxMs = math.max(1, duration.inMilliseconds).toDouble();
    final seek = (_preview[i] ?? pos.inMilliseconds.toDouble())
        .clamp(0.0, maxMs).toDouble();
    final can = _ready && !_closing && !_loading[i] && t != null;
    final name = i == 0 ? 'A' : 'B';
    final progress = duration > Duration.zero
      ? (pos.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0).toDouble()
      : 0.0;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: C.raised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.line)),
      child: SingleChildScrollView(child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Text('DECK ' + name,
              style: TextStyle(color: C.accent, fontWeight: FontWeight.bold)),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _ready && !_closing ? () => _pick(i) : null,
              icon: const Icon(Icons.queue_music_rounded, size: 18),
              label: const Text('Загрузить')),
          ]),
          const SizedBox(height: 8),
          Text(t?.title ?? 'Выберите трек',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          Text(t?.artist ?? 'Из библиотеки Cavey',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: C.muted)),
          const SizedBox(height: 12),
          Row(children: [
            Text(info?.bpm == null ? 'BPM —' : 'BPM ' + info!.bpm!.toStringAsFixed(1)),
            const SizedBox(width: 18),
            Text(info?.key == null ? 'KEY —' : 'KEY ' + info!.key!),
            if (_loading[i]) ...[
              const Spacer(),
              const SizedBox(height: 16, width: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ]),
          const SizedBox(height: 8),
          SizedBox(height: 65, child: CustomPaint(
            painter: _DeckWavePainter(info?.wave ?? const [], progress),
            child: const SizedBox.expand())),
          Slider(
            value: seek, min: 0, max: maxMs,
            onChanged: can ? (v) => setState(() => _preview[i] = v) : null,
            onChangeEnd: (v) {
              setState(() => _preview[i] = null);
              unawaited(_seek(i, Duration(milliseconds: v.round())));
            }),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(_time(pos), style: const TextStyle(color: C.muted, fontSize: 12)),
            Text(_time(duration), style: const TextStyle(color: C.muted, fontSize: 12)),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 7, runSpacing: 7, children: [
            FilledButton.icon(
              onPressed: can ? () => _playPause(i) : null,
              icon: Icon(p.state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              label: Text(p.state.playing ? 'Пауза' : 'Play')),
            OutlinedButton(
              onPressed: can ? () => setState(() => _cues[i] = pos) : null,
              child: const Text('Set CUE')),
            OutlinedButton(
              onPressed: can ? () => _seek(i, _cues[i]) : null,
              child: const Text('Go CUE')),
            OutlinedButton(
              onPressed: can && _tracks[1 - i] != null ? () => _sync(i) : null,
              child: const Text('SYNC')),
          ]),
          const SizedBox(height: 9),
          Row(children: [
            const Text('TEMPO', style: TextStyle(fontSize: 12)),
            Expanded(child: Slider(
              min: 0.85, max: 1.15,
              value: _rates[i].clamp(0.85, 1.15).toDouble(),
              onChanged: can ? (v) => setState(() => _rates[i] = v) : null,
              onChangeEnd: (_) => unawaited(_setRate(i)))),
            Text((_rates[i] * 100).toStringAsFixed(1) + '%',
              style: const TextStyle(fontSize: 12)),
          ]),
          Row(children: [
            const Text('BEAT NUDGE', style: TextStyle(fontSize: 12)),
            const Spacer(),
            IconButton(
              tooltip: 'На 20 мс назад',
              onPressed: can ? () => _seek(i, pos -
                const Duration(milliseconds: 20)) : null,
              icon: const Icon(Icons.chevron_left_rounded)),
            IconButton(
              tooltip: 'На 20 мс вперёд',
              onPressed: can ? () => _seek(i, pos +
                const Duration(milliseconds: 20)) : null,
              icon: const Icon(Icons.chevron_right_rounded)),
          ]),
          SwitchListTile(
            dense: true, contentPadding: EdgeInsets.zero,
            value: _bassCut[i],
            onChanged: can ? (v) => unawaited(_bass(i, v)) : null,
            title: const Text('Bass cut'),
            subtitle: const Text('Срезать низкие частоты при наложении',
              style: TextStyle(color: C.muted, fontSize: 11))),
        ],
      )),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: Dialog(
      insetPadding: const EdgeInsets.all(18),
      child: SizedBox(width: 1100, height: 800,
        child: Padding(padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(Icons.graphic_eq_rounded, color: C.accent),
              const SizedBox(width: 8),
              const Text('DJ CONSOLE',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const Spacer(),
              IconButton(
                onPressed: _closing ? null : () => _exit(false),
                icon: const Icon(Icons.close_rounded)),
            ]),
            Padding(padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_status, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: C.muted, fontSize: 12))),
            Expanded(child: LayoutBuilder(builder: (context, box) {
              if (box.maxWidth < 720) {
                return ListView(children: [
                  _deck(0), const SizedBox(height: 12), _deck(1),
                ]);
              }
              return Row(crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _deck(0)),
                  const SizedBox(width: 12),
                  Expanded(child: _deck(1)),
                ]);
            })),
            Row(children: [
              const Text('A'),
              Expanded(child: Slider(
                value: _cross, min: 0, max: 1,
                onChanged: _ready && !_closing ? (v) {
                  setState(() => _cross = v); _gain();
                } : null)),
              const Text('B'),
            ]),
            Row(children: [
              const Text('MASTER', style: TextStyle(color: C.muted, fontSize: 12)),
              Expanded(child: Slider(
                value: _master, min: 0, max: 0.85,
                onChanged: _ready && !_closing ? (v) {
                  setState(() => _master = v); _gain();
                } : null)),
              Text((_master * 100).round().toString() + '%',
                style: const TextStyle(color: C.muted, fontSize: 12)),
            ]),
            Row(children: [
              const Expanded(child: Text(
                'Равномощный кроссфейдер; обе деки играют одновременно без переоткрытия аудио.',
                style: TextStyle(color: C.muted, fontSize: 11))),
              TextButton(
                onPressed: _closing ? null : () => _exit(false),
                child: const Text('Закрыть')),
              FilledButton(
                onPressed: _ready && !_closing ? () => _exit(true) : null,
                child: const Text('Вернуться к плееру')),
            ]),
          ]))),
    ),
  );
}

class _DeckWavePainter extends CustomPainter {
  final List<int> wave;
  final double progress;
  _DeckWavePainter(this.wave, this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(7)),
      Paint()..color = C.surface);
    final count = wave.isEmpty ? 80 : wave.length;
    final step = size.width / count;
    final left = Paint()..color = C.accent;
    final right = Paint()..color = C.muted.withValues(alpha: 0.45);
    for (var i = 0; i < count; i++) {
      final level = (wave.isEmpty ? 0.10 : (wave[i] / 255).clamp(0.04, 1.0)).toDouble();
      final height = math.max(3.0, (size.height - 8) * level);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * step, (size.height - height) / 2,
            math.max(1.0, step - 1), height),
          const Radius.circular(1)),
        i / count <= progress ? left : right);
    }
    final x = progress.clamp(0.0, 1.0) * size.width;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height),
      Paint()..color = Colors.white..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_DeckWavePainter old) =>
    !identical(old.wave, wave) || old.progress != progress;
}
