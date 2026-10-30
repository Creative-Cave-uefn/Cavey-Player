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
      margin: const EdgeInsets.fromLTRB(0, 12, 12, 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(24), border: Border.all(color: C.line)),
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
                  : LyricsBody(key: ValueKey(t.id), track: t),
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

/// Текст песни. [big] — крупно, для режима кинотеатра
class LyricsBody extends StatefulWidget {
  final Track track;
  final bool big;
  const LyricsBody({super.key, required this.track, this.big = false});
  @override
  State<LyricsBody> createState() => _LyricsBodyState();
}

class _LyricsBodyState extends State<LyricsBody> {
  PlayerController? _player;
  LyricsService? _lyrics;
  Lyrics? _synced;
  final List<GlobalKey> _keys = [];
  int _idx = -1;
  int _shown = -2;
  DateTime _userScrolledAt = DateTime(0);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_player != null) return;
    final app = Services.of(context);
    _player = app.player..position.addListener(_onPosition);
    // Панель показывает то, что лежит в сервисе текстов, и перерисовывается,
    // когда любой поиск закончился — свой, начатый плеером при открытии трека, или повторный
    _lyrics = app.lyrics..addListener(_onLyrics);
    WidgetsBinding.instance.addPostFrameCallback((_) => _request());
  }

  @override
  void dispose() {
    _player?.position.removeListener(_onPosition);
    _lyrics?.removeListener(_onLyrics);
    super.dispose();
  }

  void _onLyrics() {
    if (mounted) setState(() {});
  }

  /// Просим текст, если его ещё нет и никто его сейчас не ищет
  Future<void> _request({bool refresh = false}) async {
    final lyrics = _lyrics, p = _player;
    if (lyrics == null || p == null || !mounted) return;
    final t = widget.track;
    if (!refresh && (lyrics.known(t) || lyrics.loading(t))) return;
    final d = await _waitDuration(p, const Duration(seconds: 4));
    if (!mounted) return;
    try {
      await lyrics.forTrack(t, d, refresh: refresh);
    } catch (_) {
      return; // покажем «не отвечает» с кнопкой повтора
    }
    // Искали, не зная длительности, и не нашли — дождёмся её и попробуем ещё раз
    if (lyrics.cached(t) == null && d == Duration.zero && mounted) {
      final d2 = await _waitDuration(p, const Duration(seconds: 15));
      if (d2 > Duration.zero && mounted) {
        try {
          await lyrics.forTrack(t, d2);
        } catch (_) {}
      }
    }
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

  int _lineAt(Lyrics ly) => ly.indexAt(_player!.position.value + const Duration(milliseconds: 250));

  /// Перерисовываем только когда сменилась строка, а не на каждый тик позиции
  void _onPosition() {
    final ly = _synced;
    if (ly == null || _player == null || !mounted) return;
    final i = _lineAt(ly);
    if (i != _idx) setState(() => _idx = i);
  }

  void _retry() {
    _shown = -2;
    unawaited(_request(refresh: true));
    setState(() {});
  }

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
    final lyrics = app.lyrics;
    final t = widget.track;
    if (!lyrics.known(t)) {
      _synced = null;
      if (lyrics.failed(t) && !lyrics.loading(t)) {
        return _Note('База текстов LRCLIB сейчас не отвечает.', onRetry: _retry);
      }
      return const Padding(
        padding: EdgeInsets.fromLTRB(22, 12, 22, 0),
        child: Align(alignment: Alignment.topLeft, child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    final ly = lyrics.cached(t);
    _synced = (ly != null && ly.synced) ? ly : null;
    if (ly == null) return _Note('Текст этой песни не нашёлся в базе LRCLIB.', onRetry: _retry);
    if (ly.instrumental) return _Note('Это инструментальная композиция, слов нет.', onRetry: _retry);
    if (!ly.synced) {
      return ListView(padding: const EdgeInsets.fromLTRB(22, 4, 22, 32), children: [
        for (final l in ly.lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(l.text, style: TextStyle(color: C.muted, fontSize: widget.big ? 24 : 15, height: 1.5, fontWeight: widget.big ? FontWeight.w600 : null)),
          ),
        _again(),
      ]);
    }
    while (_keys.length < ly.lines.length) {
      _keys.add(GlobalKey());
    }
    final idx = _idx = _lineAt(ly);
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
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: widget.big ? 10 : 6),
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 250),
                  style: TextStyle(
                    fontSize: widget.big ? 34 : 19,
                    height: widget.big ? 1.25 : 1.35,
                    fontWeight: widget.big ? FontWeight.w700 : FontWeight.w600,
                    letterSpacing: widget.big ? -0.4 : null,
                    color: i == idx ? C.text : (i < idx ? (widget.big ? const Color(0x4DFFFFFF) : C.faint) : (widget.big ? const Color(0x80FFFFFF) : C.muted)),
                  ),
                  child: Text(ly.lines[i].text.isEmpty ? '♪' : ly.lines[i].text),
                ),
              ),
            ),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: _again()),
        ]),
      ),
    );
  }
}
