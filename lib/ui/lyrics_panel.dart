import 'package:flutter/scheduler.dart';
import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import '../app.dart';
import '../core/karaoke.dart';
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

  /// Караоке: текущая строка заливается цветом по мере того, как её поют
  final bool karaoke;
  const LyricsBody({super.key, required this.track, this.big = false, this.karaoke = false});
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
    // Посчитались точные тайминги слов — перерисовываем караоке
    _karaoke = app.karaoke..addListener(_onLyrics);
    WidgetsBinding.instance.addPostFrameCallback((_) => _request());
  }

  KaraokeService? _karaoke;

  @override
  void dispose() {
    _player?.position.removeListener(_onPosition);
    _lyrics?.removeListener(_onLyrics);
    _karaoke?.removeListener(_onLyrics);
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

  /// Когда строка на самом деле начинается. В LRCLIB отметки часто стоят чуть раньше пения;
  /// если Whisper знает время первого слова — строка переключается по нему
  List<Duration>? _starts;

  int _lineAt(Lyrics ly) {
    // В панели строку подсвечиваем чуть заранее — читать удобнее. В караоке — ровно в такт, без упреждения
    final pos = _player!.position.value + (widget.karaoke ? Duration.zero : const Duration(milliseconds: 250));
    final starts = _starts;
    if (starts == null || starts.length != ly.lines.length) return ly.indexAt(pos);
    var lo = 0, hi = starts.length - 1, idx = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (starts[mid] <= pos) {
        idx = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return idx;
  }

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
    // Время слов: точное из текста (расширенный LRC) → посчитанное Whisper → разбивка по слогам
    final exact = widget.karaoke ? app.karaoke.wordsFor(t, ly) : null;
    _starts = widget.karaoke
        ? [
            for (var i = 0; i < ly.lines.length; i++)
              () {
                final at = ly.lines[i].at!;
                final w = ly.lines[i].words ?? (exact != null && i < exact.length ? exact[i] : null);
                if (w == null || w.isEmpty) return at;
                final first = w.first.start;
                // Первое слово спето позже отметки — ждём его (но не дольше 3 секунд: дальше это уже ошибка)
                return first > at && first - at < const Duration(seconds: 3) ? first : at;
              }(),
          ]
        : null;
    final idx = _idx = _lineAt(ly);
    _follow(idx);
    List<KWord> wordsOf(int i) {
      final line = ly.lines[i];
      final st = _starts;
      final end = i + 1 < ly.lines.length && ly.lines[i + 1].at != null
          ? (st != null && i + 1 < st.length ? st[i + 1] : ly.lines[i + 1].at!)
          : line.at! + const Duration(seconds: 5);
      final w = line.words ?? (exact != null && i < exact.length ? exact[i] : null);
      return (w != null && w.isNotEmpty) ? w : syllables(line.text, st != null && i < st.length ? st[i] : line.at!, end);
    }

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
                  child: widget.karaoke && i == idx && ly.lines[i].text.isNotEmpty
                      ? KaraokeText(text: ly.lines[i].text, words: wordsOf(i), player: app.player)
                      : Text(ly.lines[i].text.isEmpty ? '♪' : ly.lines[i].text),
                ),
              ),
            ),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: _again()),
        ]),
      ),
    );
  }
}


/// Строка в режиме караоке: тусклый текст, поверх — яркий, слова (или слоги) открываются каждое
/// в своё время. Перенос на несколько строк учитывается. Между обновлениями позиции от плеера
/// заливка движется плавно — досчитываем время сами
class KaraokeText extends StatefulWidget {
  final String text;
  final List<KWord> words;
  final PlayerController player;
  const KaraokeText({super.key, required this.text, required this.words, required this.player});

  @override
  State<KaraokeText> createState() => _KaraokeTextState();
}

class _KaraokeTextState extends State<KaraokeText> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => setState(() {}))..start();
  Duration _lastPos = Duration.zero;
  DateTime _lastAt = DateTime.now();

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Duration _now() {
    final p = widget.player;
    final pos = p.position.value;
    if (pos != _lastPos) {
      _lastPos = pos;
      _lastAt = DateTime.now();
    }
    return p.playing ? pos + DateTime.now().difference(_lastAt) : pos;
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    final now = _now();
    // Насколько спето каждое слово: 0 — ещё нет, 1 — целиком
    final fills = [
      for (final w in widget.words)
        w.end <= w.start
            ? (now >= w.start ? 1.0 : 0.0)
            : ((now - w.start).inMilliseconds / (w.end - w.start).inMilliseconds).clamp(0.0, 1.0),
    ];
    final done = fills.every((f) => f >= 1);
    if (done) {
      _ticker.stop();
    } else if (!_ticker.isActive) {
      _ticker.start(); // перемотали назад внутри строки
    }
    return LayoutBuilder(builder: (context, box) {
      final tp = TextPainter(
        text: TextSpan(text: widget.text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: box.maxWidth);
      final rects = <Rect>[];
      for (var k = 0; k < widget.words.length; k++) {
        final f = fills[k];
        if (f <= 0) continue;
        final w = widget.words[k];
        final from = w.from.clamp(0, widget.text.length), to = w.to.clamp(0, widget.text.length);
        if (to <= from) continue;
        final boxes = tp.getBoxesForSelection(TextSelection(baseOffset: from, extentOffset: to));
        var left = boxes.fold<double>(0, (a, b) => a + (b.right - b.left)) * f;
        for (final b in boxes) {
          if (left <= 0) break;
          final bw = math.min(left, b.right - b.left);
          rects.add(Rect.fromLTRB(b.left, b.top - 2, b.left + bw, b.bottom + 2));
          left -= b.right - b.left;
        }
      }
      tp.dispose();
      return Stack(children: [
        Text(widget.text, style: style.copyWith(color: style.color?.withValues(alpha: 0.35))),
        ClipPath(
          clipper: _Reveal(rects),
          child: Text(widget.text, style: style.copyWith(color: Colors.white)),
        ),
      ]);
    });
  }
}

class _Reveal extends CustomClipper<Path> {
  final List<Rect> rects;
  _Reveal(this.rects);

  @override
  Path getClip(Size size) {
    final path = Path();
    for (final r in rects) {
      path.addRect(r);
    }
    return path;
  }

  @override
  bool shouldReclip(_Reveal old) => true;
}
