import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import '../app.dart';
import '../core/lyrics.dart';
import '../core/models.dart';
import '../core/player.dart';
import 'theme.dart';

/// Панель справа с текстом песни. Синхронный текст подсвечивается по ходу трека,
/// клик по строке перематывает к ней.
class LyricsPanel extends StatelessWidget {
  const LyricsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return Container(
      width: 340,
      decoration: const BoxDecoration(color: C.surface, border: Border(left: BorderSide(color: C.line))),
      child: ListenableBuilder(
        listenable: app.player,
        builder: (context, _) {
          final t = app.player.current;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 8, 8),
              child: Row(children: [
                Expanded(child: Text('Текст песни', style: display(16))),
                IconButton(
                  tooltip: 'Закрыть',
                  onPressed: () => app.player.lyricsOpen.value = false,
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
              ]),
            ),
            Expanded(
              child: t == null
                  ? const _Note('Включите трек, и здесь появится его текст.')
                  : _LyricsBody(key: ValueKey(t.id), track: t),
            ),
          ]);
        },
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  final VoidCallback? onRetry;
  const _Note(this.text, {this.onRetry});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 8, 22, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(text, style: const TextStyle(color: C.faint, height: 1.5)),
          if (onRetry != null) ...[
            const SizedBox(height: 10),
            TextButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded, size: 18), label: const Text('Искать снова')),
          ],
        ]),
      );
}

class _LyricsBody extends StatefulWidget {
  final Track track;
  const _LyricsBody({super.key, required this.track});
  @override
  State<_LyricsBody> createState() => _LyricsBodyState();
}

class _LyricsBodyState extends State<_LyricsBody> {
  Future<Lyrics?>? _future;
  PlayerController? _player;
  Lyrics? _synced;
  final List<GlobalKey> _keys = [];
  int _idx = -1;
  int _shown = -2;
  DateTime _userScrolledAt = DateTime(0);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_future != null) return;
    _player = Services.of(context).player..position.addListener(_onPosition);
    _start();
  }

  @override
  void dispose() {
    _player?.position.removeListener(_onPosition);
    super.dispose();
  }

  void _start({bool refresh = false}) {
    final app = Services.of(context);
    final player = app.player;
    _synced = null;
    _idx = -1;
    _shown = -2;
    _future = () async {
      var d = await _waitDuration(player, const Duration(seconds: 4));
      var ly = await app.lyrics.forTrack(widget.track, d, refresh: refresh);
      // Искали, не зная длительности, и не нашли — дождёмся её и попробуем ещё раз
      if (ly == null && d == Duration.zero && mounted) {
        d = await _waitDuration(player, const Duration(seconds: 15));
        if (d > Duration.zero && mounted) ly = await app.lyrics.forTrack(widget.track, d, refresh: true);
      }
      _synced = (ly != null && ly.synced) ? ly : null;
      _onPosition();
      return ly;
    }();
  }

  /// Длительность помогает выбрать правильную версию текста. При стриминге с Диска
  /// она появляется не сразу, поэтому ждём её по событию плеера, а не фиксированное время.
  static Future<Duration> _waitDuration(PlayerController p, Duration limit) async {
    if (p.duration > Duration.zero) return p.duration;
    final done = Completer<Duration>();
    void check() {
      if (p.duration > Duration.zero && !done.isCompleted) done.complete(p.duration);
    }

    p.addListener(check);
    try {
      return await done.future.timeout(limit, onTimeout: () => p.duration);
    } finally {
      p.removeListener(check);
    }
  }

  /// Перерисовываем только когда сменилась строка, а не на каждый тик позиции
  void _onPosition() {
    final ly = _synced;
    final p = _player;
    if (ly == null || p == null || !mounted) return;
    final i = ly.indexAt(p.position.value + const Duration(milliseconds: 250));
    if (i != _idx) setState(() => _idx = i);
  }

  void _retry() => setState(() => _start(refresh: true));

  void _follow(int idx) {
    if (idx == _shown || idx < 0 || idx >= _keys.length) return;
    // Человек сам листает текст — не утаскиваем его обратно несколько секунд
    if (DateTime.now().difference(_userScrolledAt) < const Duration(seconds: 4)) return;
    _shown = idx;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[idx].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, alignment: 0.35, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
      }
    });
  }

  bool _onScroll(UserScrollNotification n) {
    if (n.direction != ScrollDirection.idle) _userScrolledAt = DateTime.now();
    return false;
  }

  Widget _again() => Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _retry,
            child: const Text('Не тот текст? Искать заново', style: TextStyle(color: C.faint, fontSize: 13)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return FutureBuilder<Lyrics?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(22, 12, 22, 0),
            child: Align(alignment: Alignment.topLeft, child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        if (snap.hasError) {
          return _Note('База текстов LRCLIB сейчас не отвечает.', onRetry: _retry);
        }
        final ly = snap.data;
        if (ly == null) return _Note('Текст этой песни не нашёлся в базе LRCLIB.', onRetry: _retry);
        if (ly.instrumental) return _Note('Это инструментальная композиция, слов нет.', onRetry: _retry);
        if (!ly.synced) {
          return ListView(padding: const EdgeInsets.fromLTRB(22, 4, 22, 32), children: [
            for (final l in ly.lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(l.text, style: const TextStyle(color: C.muted, fontSize: 15, height: 1.5)),
              ),
            _again(),
          ]);
        }
        while (_keys.length < ly.lines.length) {
          _keys.add(GlobalKey());
        }
        final idx = _idx;
        _follow(idx);
        return NotificationListener<UserScrollNotification>(
          onNotification: _onScroll,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 200),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var i = 0; i < ly.lines.length; i++)
                InkWell(
                  key: _keys[i],
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    _userScrolledAt = DateTime(0); // клик по строке — снова следим за песней
                    app.player.seek(ly.lines[i].at!);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 200),
                      style: TextStyle(
                        fontSize: 19,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                        color: i == idx ? C.text : (i < idx ? C.faint : C.muted),
                      ),
                      child: Text(ly.lines[i].text.isEmpty ? '♪' : ly.lines[i].text),
                    ),
                  ),
                ),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: _again()),
            ]),
          ),
        );
      },
    );
  }
}
