import 'package:flutter/scheduler.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;
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
  int _offMs = 0; // Ж7: поправка времени текста (мс)

  int _leadIdx = -1; // К3: строка, к которой надо начать прокрутку (на 180 мс раньше)

  int _lineAt(Lyrics ly, {int leadMs = 0}) {
    // В панели строку подсвечиваем чуть заранее — читать удобнее. В караоке — ровно в такт, без упреждения
    final pos = _player!.position.value + (widget.karaoke ? Duration(milliseconds: _offMs + leadMs) : const Duration(milliseconds: 250));
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
    final lead = widget.karaoke ? _lineAt(ly, leadMs: 180) : i;
    if (i != _idx || lead != _leadIdx) {
      setState(() {
        _idx = i;
        _leadIdx = lead;
      });
    }
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

  Widget _again() {
    final ly = _synced;
    final note = ly == null
        ? null
        : ly.approx
            ? 'Версия текста может отличаться: длительность в базе не совпадает с треком'
            : switch (ly.origin) {
                'ultrastar' => 'Слоги из файла UltraStar рядом с треком',
                'ass' => 'Слоги из файла .ass рядом с треком',
                'lrc' => 'Текст из файла рядом с треком или из самого трека',
                _ => null,
              };
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (note != null) Text(note, style: const TextStyle(color: C.faint, fontSize: 12, height: 1.4)),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _retry,
            child: const Text('Не тот текст? Искать заново', style: TextStyle(color: C.faint, fontSize: 13)),
          ),
        ),
      ]),
    );
  }

  /// К2: текущая строка в полный размер, остальные тем меньше, прозрачнее и размытее, чем дальше от неё
  Widget _focus(int offset, Widget child) {
    if (!widget.big) return child;
    final d = offset.abs().clamp(0, 4).toDouble();
    return TweenAnimationBuilder<double>(
      tween: Tween(end: d),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutBack,
      child: child,
      builder: (context, v, child) {
        final k = v.clamp(0.0, 4.0);
        final scale = k <= 0 ? 1.0 : 0.94 - 0.005 * math.min(k, 4);
        final sigma = k < 1 ? 0.0 : math.min(3.0, 0.8 + 0.7 * (k - 1));
        Widget w = Transform.scale(scale: scale, alignment: Alignment.centerLeft, child: child);
        if (sigma > 0.05) {
          w = ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.decal), child: w);
        }
        return w;
      },
    );
  }

  /// К4: если до следующей строки больше 4 секунд без слов, показываем три точки, которые заполняются к её началу
  Widget _breakDots(List<KWord> words, Duration next, PlayerController player) {
    if (words.isEmpty) return const SizedBox.shrink();
    final from = words.last.end;
    if (next - from < const Duration(seconds: 4)) return const SizedBox.shrink();
    return ValueListenableBuilder<Duration>(
      valueListenable: player.position,
      builder: (context, pos, _) {
        final p = Duration(milliseconds: _offMs) + pos;
        if (p < from) return const SizedBox.shrink();
        final prog = ((p - from).inMilliseconds / (next - from).inMilliseconds).clamp(0.0, 1.0);
        final breathe = 1 + 0.15 * math.sin(p.inMilliseconds / 350);
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Row(children: [
            for (var k = 0; k < 3; k++)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Transform.scale(
                  scale: breathe,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.25 + 0.75 * (prog * 3 - k).clamp(0.0, 1.0)),
                    ),
                  ),
                ),
              ),
          ]),
        );
      },
    );
  }

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
        _PlainTiming(track: t, lyrics: ly), // Л4
      ]);
    }
    while (_keys.length < ly.lines.length) {
      _keys.add(GlobalKey());
    }
    // Время слов: точное из текста (расширенный LRC) → посчитанное Whisper → разбивка по слогам
    _offMs = widget.karaoke ? app.karaoke.offsetMs(t) : 0;
    final exact = widget.karaoke ? app.karaoke.wordsFor(t, ly) : null;
    _starts = widget.karaoke
        ? KaraokeAligner.lineStarts([for (final l in ly.lines) l.at!], [
            for (var i = 0; i < ly.lines.length; i++)
              () {
                final w = ly.lines[i].words ?? (exact != null && i < exact.length ? exact[i] : null);
                return w == null || w.isEmpty ? null : w.first.start;
              }(),
          ])
        : null;
    final idx = _idx = _lineAt(ly);
    _leadIdx = widget.karaoke ? _lineAt(ly, leadMs: 180) : idx;
    _follow(math.max(idx, _leadIdx)); // К3: прокрутка начинается за 180 мс до новой строки
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
          for (var i = 0; i < ly.lines.length; i++) ...[
            _focus(
              i - idx,
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
                      ? KaraokeText(text: ly.lines[i].text, words: wordsOf(i), player: app.player, shiftMs: _offMs)
                      : Text(ly.lines[i].text.isEmpty ? '♪' : ly.lines[i].text),
                ),
              ),
              ),
            ),
            // К4: долгий проигрыш между строками — три дышащие точки
            if (widget.big && widget.karaoke && i == idx && i + 1 < ly.lines.length) _breakDots(wordsOf(i), ly.lines[i + 1].at!, app.player),
          ],
          Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: _again()),
          if (widget.karaoke) _KaraokeTools(track: t, lyrics: ly),
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
  final int shiftMs; // Ж7: поправка времени
  const KaraokeText({super.key, required this.text, required this.words, required this.player, this.shiftMs = 0});

  @override
  State<KaraokeText> createState() => _KaraokeTextState();
}

class _KaraokeTextState extends State<KaraokeText> with SingleTickerProviderStateMixin {
  // И5: раскладку текста и прямоугольники слов считаем один раз на текст, стиль и ширину;
  // каждый кадр меняется только степень заливки, а перерисовывается один CustomPaint
  final ValueNotifier<int> _frame = ValueNotifier(0);
  late final Ticker _ticker = createTicker(_onTick)..start();
  Duration _lastPos = Duration.zero;
  DateTime _lastAt = DateTime.now();
  Duration _lastFrame = Duration.zero;

  _Layout? _layout;
  String? _layoutKey;

  @override
  void initState() {
    super.initState();
    widget.player.position.addListener(_wake);
  }

  /// Перемотали назад внутри строки или сняли с паузы — заливка снова должна двигаться
  void _wake() {
    if (!_ticker.isActive) _ticker.start();
  }

  @override
  void dispose() {
    widget.player.position.removeListener(_wake);
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    // не чаще 60 кадров в секунду, даже на мониторе 144 Гц
    if (elapsed - _lastFrame < const Duration(milliseconds: 16)) return;
    _lastFrame = elapsed;
    _frame.value++;
  }

  Duration _now() {
    final p = widget.player;
    final pos = p.position.value;
    if (pos != _lastPos) {
      _lastPos = pos;
      _lastAt = DateTime.now();
    }
    final shift = Duration(milliseconds: widget.shiftMs);
    return (p.playing ? pos + DateTime.now().difference(_lastAt) : pos) + shift;
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    return LayoutBuilder(builder: (context, box) {
      final scaler = MediaQuery.textScalerOf(context);
      final key = '${widget.text}|${box.maxWidth}|${style.fontSize}|${style.fontWeight}|${style.height}|${style.letterSpacing}|${scaler.hashCode}';
      if (_layoutKey != key || _layout == null) {
        _layout?.dispose();
        _layout = _Layout.build(widget.text, widget.words, style, box.maxWidth, Directionality.of(context), scaler);
        _layoutKey = key;
        if (!_ticker.isActive) _ticker.start();
      }
      final l = _layout!;
      return CustomPaint(
        size: Size(box.maxWidth, l.height),
        painter: _KaraokePainter(l, widget.words, _now, _frame, () {
          if (_ticker.isActive) _ticker.stop();
        }),
      );
    });
  }
}

/// Раскладка строки: три варианта текста (тусклый, яркий, свечение) и прямоугольники каждого слова
class _Layout {
  final TextPainter dim, bright, glow;
  final List<List<Rect>> wordBoxes;
  final double height, fontSize;
  _Layout(this.dim, this.bright, this.glow, this.wordBoxes, this.height, this.fontSize);

  static _Layout build(String text, List<KWord> words, TextStyle style, double maxWidth, TextDirection dir, TextScaler scaler) {
    TextPainter make(TextStyle st) => TextPainter(text: TextSpan(text: text, style: st), textDirection: dir, textScaler: scaler)
      ..layout(maxWidth: maxWidth);
    final dim = make(style.copyWith(color: style.color?.withValues(alpha: 0.35)));
    final bright = make(style.copyWith(color: Colors.white));
    final glow = make(style.copyWith(
      foreground: Paint()
        ..color = const Color(0x66FFFFFF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    ));
    final boxes = <List<Rect>>[];
    for (final w in words) {
      final from = w.from.clamp(0, text.length), to = w.to.clamp(0, text.length);
      if (to <= from) {
        boxes.add(const []);
        continue;
      }
      boxes.add([
        for (final b in bright.getBoxesForSelection(TextSelection(baseOffset: from, extentOffset: to)))
          Rect.fromLTRB(b.left, b.top - 2, b.right, b.bottom + 2),
      ]);
    }
    return _Layout(dim, bright, glow, boxes, bright.height, style.fontSize ?? 20);
  }

  void dispose() {
    dim.dispose();
    bright.dispose();
    glow.dispose();
  }
}

class _KaraokePainter extends CustomPainter {
  final _Layout l;
  final List<KWord> words;
  final Duration Function() now;
  final VoidCallback onDone;
  _KaraokePainter(this.l, this.words, this.now, Listenable repaint, this.onDone) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final t = now();
    l.dim.paint(canvas, Offset.zero);
    final edge = l.fontSize * 0.35; // К1: мягкий край заливки шириной около полбуквы
    final sung = <Rect>[]; // целиком спетое — для свечения
    var done = true;
    for (var k = 0; k < words.length; k++) {
      final w = words[k];
      final f = w.end <= w.start ? (t >= w.start ? 1.0 : 0.0) : ((t - w.start).inMilliseconds / (w.end - w.start).inMilliseconds).clamp(0.0, 1.0);
      if (f < 1) done = false;
      if (f <= 0) continue;
      final boxes = l.wordBoxes[k];
      var left = boxes.fold<double>(0, (a, b) => a + b.width) * f;
      for (final r in boxes) {
        if (left <= 0) break;
        final bw = math.min(left, r.width);
        left -= r.width;
        if (bw >= r.width - 0.5) {
          sung.add(r);
          _clipped(canvas, r);
        } else {
          final x = r.left + bw;
          final ew = math.min(edge, bw);
          _clipped(canvas, Rect.fromLTRB(r.left, r.top, x - ew, r.bottom));
          _soft(canvas, Rect.fromLTRB(x - ew, r.top, x, r.bottom));
        }
      }
    }
    // К1: спетое слегка светится
    if (sung.isNotEmpty) {
      canvas.save();
      final path = Path();
      for (final r in sung) {
        path.addRect(r.inflate(2));
      }
      canvas.clipPath(path);
      l.glow.paint(canvas, Offset.zero);
      canvas.restore();
    }
    if (done) WidgetsBinding.instance.addPostFrameCallback((_) => onDone());
  }

  void _clipped(Canvas canvas, Rect r) {
    if (r.width <= 0) return;
    canvas.save();
    canvas.clipRect(r);
    l.bright.paint(canvas, Offset.zero);
    canvas.restore();
  }

  void _soft(Canvas canvas, Rect r) {
    if (r.width <= 0) return;
    canvas.saveLayer(r, Paint());
    canvas.clipRect(r);
    l.bright.paint(canvas, Offset.zero);
    canvas.drawRect(
      r,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = const LinearGradient(colors: [Colors.white, Color(0x00FFFFFF)]).createShader(r),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_KaraokePainter old) => !identical(old.l, l) || old.words != words;
}

/// Ж6 и Ж7: пересчёт караоке и сдвиг времени текста на ±50 мс (запоминается на трек)
class _KaraokeTools extends StatelessWidget {
  final Track track;
  final Lyrics lyrics;
  const _KaraokeTools({required this.track, required this.lyrics});

  @override
  Widget build(BuildContext context) {
    final k = Services.of(context).karaoke;
    return ListenableBuilder(
      listenable: k,
      builder: (context, _) {
        final off = k.trackOffsetMs(track);
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 20, 8, 0),
          child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Text('Время текста:', style: TextStyle(color: C.faint, fontSize: 12)),
            IconButton(tooltip: 'Текст позже на 50 мс', onPressed: () => k.nudge(track, -50), icon: const Icon(Icons.remove_rounded, size: 18)),
            Text(off == 0 ? 'как есть' : '${off > 0 ? '+' : ''}$off мс', style: const TextStyle(color: C.muted, fontSize: 12)),
            IconButton(tooltip: 'Текст раньше на 50 мс', onPressed: () => k.nudge(track, 50), icon: const Icon(Icons.add_rounded, size: 18)),
            TextButton.icon(
              onPressed: () => k.recompute(track, lyrics),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Пересчитать караоке'),
            ),
          ]),
        );
      },
    );
  }
}


/// Л4: текст есть, а времени нет — предложить расставить время строк по звуку (Whisper)
class _PlainTiming extends StatefulWidget {
  final Track track;
  final Lyrics lyrics;
  const _PlainTiming({required this.track, required this.lyrics});

  @override
  State<_PlainTiming> createState() => _PlainTimingState();
}

class _PlainTimingState extends State<_PlainTiming> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.karaoke,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('У этого текста нет времени строк.', style: TextStyle(color: C.faint, fontSize: 12)),
          TextButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    setState(() => _busy = true);
                    try {
                      final ok = await app.karaoke.timePlain(widget.track, widget.lyrics, app.lyrics);
                      if (!ok && mounted) app.lib.messages.add('Не получилось расставить время строк');
                    } catch (e) {
                      app.lib.messages.add('Не получилось: ${'$e'.replaceFirst('Exception: ', '')}');
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
            icon: _busy
                ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.timer_outlined, size: 16),
            label: Text(_busy && app.karaoke.status.isNotEmpty ? app.karaoke.status : 'Расставить время по звуку'),
          ),
        ]),
      ),
    );
  }
}
