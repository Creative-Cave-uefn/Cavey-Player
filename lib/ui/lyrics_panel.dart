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
import 'shell.dart' show SidePanelSlot;
import 'theme.dart';

/// Панель справа с текстом песни. Синхронный текст подсвечивается по ходу трека,
/// клик по строке перематывает к ней.
class LyricsPanel extends StatelessWidget {
  const LyricsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return Container(
      width: SidePanelSlot.panelWidth,
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
/// Номер текущей строки. Строки списка подписаны на него сами и перестраиваются только тогда, когда у них поменялось
/// положение относительно текущей (раньше на каждую смену строки перестраивался весь список)
class _ActiveLine extends ChangeNotifier {
  int idx = -1;
  int lead = -1;

  void set(int i, int l) {
    if (i == idx && l == lead) return;
    idx = i;
    lead = l;
    notifyListeners();
  }

  /// Без уведомления: во время сборки подписчиков трогать нельзя
  void reset(int i, int l) {
    idx = i;
    lead = l;
  }
}

class LyricsBody extends StatefulWidget {
  final Track track;
  final bool big;

  /// Караоке: текущая строка заливается цветом по мере того, как её поют
  final bool karaoke;
  const LyricsBody({super.key, required this.track, this.big = false, this.karaoke = false});
  @override
  State<LyricsBody> createState() => _LyricsBodyState();
}

class _LyricsBodyState extends State<LyricsBody> with SingleTickerProviderStateMixin {
  PlayerController? _player;
  LyricsService? _lyrics;
  Lyrics? _synced;
  List<GlobalKey> _keys = [];
  String? _keysTrack;
  int _shown = -2;
  DateTime _userScrolledAt = DateTime(0);
  final _active = _ActiveLine();
  Lyrics? _builtFor;
  late final Ticker _ticker = createTicker((_) => _tick());

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_player != null) return;
    final app = Services.of(context);
    // Строка переключается на каждый кадр, пока песня играет; на паузе кадры не тратятся.
    // Перемотка и пауза будят проверку сразу
    _player = app.player
      ..position.addListener(_wake)
      ..addListener(_wake);
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
    _player?.position.removeListener(_wake);
    _player?.removeListener(_wake);
    _lyrics?.removeListener(_onLyrics);
    _karaoke?.removeListener(_onLyrics);
    _ticker.dispose();
    _active.dispose();
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
  final int _offMs = 0; // Ж7: поправка времени текста (мс); ручного сдвига больше нет

  int _lineAt(Lyrics ly, {int leadMs = 0}) {
    // В панели строку подсвечиваем чуть заранее — читать удобнее. В караоке — ровно в такт, без упреждения.
    // Время — только с общих часов плеера, те же, по которым заливаются слова
    final pos = _player!.now() + (widget.karaoke ? Duration(milliseconds: _offMs + leadMs) : const Duration(milliseconds: 250));
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

  /// Позиция или состояние плеера изменились (перемотка, пауза, пуск): проверяем строку сразу и,
  /// если песня играет, снова включаем проверку на каждый кадр
  void _wake() {
    if (!mounted) return;
    _updateIndex();
    if (_player?.playing == true && !_ticker.isActive) _ticker.start();
  }

  void _tick() {
    if (!mounted) return;
    _updateIndex();
    if (_player?.playing != true && _ticker.isActive) _ticker.stop();
  }

  /// Проверка текущей строки: сообщаем только когда она сменилась, и тогда перестраиваются только строки рядом с ней
  void _updateIndex() {
    final ly = _synced, p = _player;
    if (ly == null || p == null) return;
    final i = _lineAt(ly);
    final lead = widget.karaoke ? _lineAt(ly, leadMs: 180) : i;
    _active.set(i, lead);
    _follow(math.max(i, lead)); // К3: прокрутка начинается за 180 мс до новой строки
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
      if (!mounted || idx >= _keys.length) return;
      final ctx = _keys[idx].currentContext;
      if (ctx != null) {
        // Кинотеатр: текущая строка всегда на середине высоты, и шаг между строками везде одинаковый
        // (раньше первая строка стояла по центру, а остальные выше, и между первой и второй был большой скачок)
        Scrollable.ensureVisible(ctx,
            alignment: widget.big ? 0.5 : 0.35, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
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
                'betterlyrics' => 'Текст и тайминги: Better Lyrics',
                'musixmatch' => 'Синхронизация слов: Musixmatch',
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
            child: Text(l.text, style: TextStyle(color: C.muted, fontSize: widget.big ? 24 : 15, height: 1.5, fontWeight: widget.big ? FontWeight.w700 : null)),
          ),
        _again(),
        _PlainTiming(track: t, lyrics: ly), // Л4
      ]);
    }
    if (_keysTrack != t.id) {
      _keysTrack = t.id;
      _keys = [];
    }
    while (_keys.length < ly.lines.length) {
      _keys.add(GlobalKey());
    }
    // Анимация — по тому, что дал источник текста: время слогов — по слогам, время слов — по словам,
    // только время строк — по строкам. Своё время слов (Whisper, разбивка на слоги) не подставляем,
    // ручного сдвига времени больше нет
    _starts = widget.karaoke
        ? KaraokeAligner.lineStarts([for (final l in ly.lines) l.at!], [
            for (var i = 0; i < ly.lines.length; i++)
              () {
                final w = ly.lines[i].words;
                return w == null || w.isEmpty ? null : w.first.start;
              }(),
          ])
        : null;
    if (!identical(_builtFor, ly)) {
      // Другой текст (или другой трек): строки создаются заново, текущая строка и прокрутка определяются с нуля
      _builtFor = ly;
      _shown = -2;
      _active.reset(_lineAt(ly), widget.karaoke ? _lineAt(ly, leadMs: 180) : _lineAt(ly));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateIndex();
      if (_player?.playing == true && !_ticker.isActive) _ticker.start();
    });

    return NotificationListener<UserScrollNotification>(
      onNotification: _onScroll,
      child: LayoutBuilder(builder: (context, box) => ScrollConfiguration(
        // В кинотеатре полоса прокрутки у текста не нужна
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
        // В кинотеатре сверху и снизу пустое место: и первая, и последняя строки могут встать на середину высоты
        padding: EdgeInsets.fromLTRB(
            14,
            widget.big && box.maxHeight.isFinite ? math.max(4.0, box.maxHeight * 0.5 - 31) : 4,
            14,
            widget.big && box.maxHeight.isFinite ? math.max(200.0, box.maxHeight * 0.5) : 200),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < ly.lines.length; i++)
            _LyricLine(
              key: ValueKey('${t.id}:$i'),
              index: i,
              active: _active,
              ly: ly,
              big: widget.big,
              karaoke: widget.karaoke,
              player: app.player,
              itemKey: _keys[i],
              onTap: () {
                _userScrolledAt = DateTime(0); // клик по строке — снова следим за песней
                app.player.seek(ly.lines[i].at!);
              },
            ),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: _again()),
        ]),
      ))),
    );
  }
}

/// Одна строка текста. Подписана на номер текущей строки и перестраивается, только когда её положение относительно
/// текущей изменилось в пределах окна ±5; дальние строки не перестраиваются совсем.
/// Размытие — только у строк в окне ±4, у остальных одна прозрачность; каждая строка в своём RepaintBoundary
class _LyricLine extends StatefulWidget {
  final int index;
  final _ActiveLine active;
  final Lyrics ly;
  final bool big;
  final bool karaoke;
  final PlayerController player;
  final GlobalKey itemKey;
  final VoidCallback onTap;
  const _LyricLine({
    super.key,
    required this.index,
    required this.active,
    required this.ly,
    required this.big,
    required this.karaoke,
    required this.player,
    required this.itemKey,
    required this.onTap,
  });

  @override
  State<_LyricLine> createState() => _LyricLineState();
}

class _LyricLineState extends State<_LyricLine> {
  late int _bucket;

  int _bucketOf() => math.max(-5, math.min(5, widget.index - widget.active.idx));

  @override
  void initState() {
    super.initState();
    _bucket = _bucketOf();
    widget.active.addListener(_onActive);
  }

  @override
  void didUpdateWidget(_LyricLine old) {
    super.didUpdateWidget(old);
    if (!identical(old.active, widget.active)) {
      old.active.removeListener(_onActive);
      widget.active.addListener(_onActive);
    }
    _bucket = _bucketOf();
  }

  @override
  void dispose() {
    widget.active.removeListener(_onActive);
    super.dispose();
  }

  void _onActive() {
    final b = _bucketOf();
    if (b == _bucket || !mounted) return;
    setState(() => _bucket = b);
  }

  /// К2: текущая строка в полный размер, остальные тем меньше, прозрачнее и размытее, чем дальше от неё
  Widget _focus(int offset, Widget child) {
    final d = math.min(offset.abs(), 4).toDouble();
    final blur = offset.abs() <= 4;
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
        if (blur && sigma > 0.05) {
          w = ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.decal), child: w);
        }
        return w;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.index;
    final off = i - widget.active.idx;
    final line = widget.ly.lines[i];
    final words = line.words ?? const <KWord>[];
    final big = widget.big;
    final now = off == 0;
    final Widget row = InkWell(
      key: widget.itemKey,
      borderRadius: BorderRadius.circular(8),
      onTap: widget.onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: big ? 10 : 6),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 250),
          style: TextStyle(
            fontSize: big ? 34 : 19,
            height: big ? 1.25 : 1.35,
            fontWeight: big ? FontWeight.w700 : FontWeight.w600,
            letterSpacing: big ? -0.4 : null,
            color: now ? C.text : (off < 0 ? (big ? const Color(0x4DFFFFFF) : C.faint) : (big ? const Color(0x80FFFFFF) : C.muted)),
          ),
          child: widget.karaoke && now && line.text.isNotEmpty && words.isNotEmpty
              ? KaraokeText(text: line.text, words: words, player: widget.player)
              : Text(line.text.isEmpty ? '♪' : line.text),
        ),
      ),
    );
    final lines = widget.ly.lines;
    return RepaintBoundary(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        big ? _focus(off, row) : row,
        // К4: долгий проигрыш между строками — три дышащие точки
        if (big && widget.karaoke && now && i + 1 < lines.length && lines[i + 1].at != null)
          _BreakDots(words: words, next: lines[i + 1].at!, player: widget.player),
      ]),
    );
  }
}

/// К4: если до следующей строки больше 4 секунд без слов, показываем три точки, которые заполняются к её началу.
/// Время берёт с общих часов плеера и обновляется на каждый кадр, пока песня играет
class _BreakDots extends StatefulWidget {
  final List<KWord> words;
  final Duration next;
  final PlayerController player;
  const _BreakDots({required this.words, required this.next, required this.player});

  @override
  State<_BreakDots> createState() => _BreakDotsState();
}

class _BreakDotsState extends State<_BreakDots> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_wake);
    widget.player.position.addListener(_wake);
    if (widget.player.playing) _ticker.start();
  }

  @override
  void dispose() {
    widget.player.removeListener(_wake);
    widget.player.position.removeListener(_wake);
    _ticker.dispose();
    super.dispose();
  }

  void _wake() {
    if (!mounted) return;
    if (widget.player.playing && !_ticker.isActive) _ticker.start();
    setState(() {});
  }

  void _onTick(Duration _) {
    if (!mounted) return;
    setState(() {});
    if (!widget.player.playing) _ticker.stop();
  }

  @override
  Widget build(BuildContext context) {
    final words = widget.words;
    if (words.isEmpty) return const SizedBox.shrink();
    final from = words.last.end;
    final next = widget.next;
    if (next - from < const Duration(seconds: 4)) return const SizedBox.shrink();
    final p = widget.player.now();
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
  }
}

/// Строка в режиме караоке: тусклый текст, поверх — яркий, слова (или слоги) открываются каждое
/// в своё время. Перенос на несколько строк учитывается. Время берётся с общих часов плеера
/// (PlayerController.now), поэтому заливка движется плавно между событиями позиции и совпадает со сменой строки
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
  late final Ticker _ticker = createTicker(_onTick);
  Duration _lastFrame = Duration.zero;

  _Layout? _layout;
  String? _layoutKey;
  List<KWord>? _layoutWords;

  @override
  void initState() {
    super.initState();
    widget.player.position.addListener(_wake);
    widget.player.addListener(_wake);
    _ticker.start();
  }

  /// Перемотали назад внутри строки или сняли с паузы — заливка снова должна двигаться
  void _wake() {
    if (_ticker.isActive || !mounted) return;
    _lastFrame = Duration.zero; // после остановки счёт времени тикера начинается с нуля
    _ticker.start();
  }

  @override
  void dispose() {
    widget.player.position.removeListener(_wake);
    widget.player.removeListener(_wake);
    _ticker.dispose();
    _frame.dispose();
    _layout?.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    // не чаще 60 кадров в секунду, даже на мониторе 144 Гц
    if (elapsed - _lastFrame < const Duration(milliseconds: 16)) return;
    _lastFrame = elapsed;
    _frame.value++;
    // На паузе после последней перерисовки кадры больше не нужны: нагрузка на процессор падает до нуля
    if (!widget.player.playing) _ticker.stop();
  }

  Duration _now() => widget.player.now() + Duration(milliseconds: widget.shiftMs);

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    return LayoutBuilder(builder: (context, box) {
      final scaler = MediaQuery.textScalerOf(context);
      final key = '${widget.text}|${box.maxWidth}|${style.fontSize}|${style.fontWeight}|${style.height}|${style.letterSpacing}|${scaler.hashCode}';
      if (_layoutKey != key || _layout == null || !identical(_layoutWords, widget.words)) {
        _layout?.dispose();
        _layout = _Layout.build(widget.text, widget.words, style, box.maxWidth, Directionality.of(context), scaler);
        _layoutKey = key;
        _layoutWords = widget.words;
        _wake();
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

/// Раскладка строки: тексты (тусклый, яркий, свечение, мягкий край) и прямоугольники каждого слова
class _Layout {
  final TextPainter dim, bright, glow, edge;
  final List<List<Rect>> wordBoxes;
  final double height, fontSize;

  /// Ширина мягкого края заливки (около полбуквы)
  final double edgeWidth;

  /// Когда спето последнее слово
  final Duration endAll;

  /// Готовая картинка полностью спетой строки: когда строка спета целиком, она больше не пересчитывается
  ui.Picture? finished;
  _Layout(this.dim, this.bright, this.glow, this.edge, this.wordBoxes, this.height, this.fontSize, this.edgeWidth, this.endAll);

  static _Layout build(String text, List<KWord> words, TextStyle style, double maxWidth, TextDirection dir, TextScaler scaler) {
    TextPainter make(TextStyle st) => TextPainter(text: TextSpan(text: text, style: st), textDirection: dir, textScaler: scaler)
      ..layout(maxWidth: maxWidth);
    final fontSize = style.fontSize ?? 20;
    final edgeWidth = fontSize * 0.35; // К1: мягкий край заливки шириной около полбуквы
    final dim = make(style.copyWith(color: style.color?.withValues(alpha: 0.35)));
    final bright = make(style.copyWith(color: Colors.white));
    final glow = make(style.copyWith(
      foreground: Paint()
        ..color = const Color(0x66FFFFFF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    ));
    // Мягкий край без saveLayer: яркий текст с градиентной прозрачностью в шейдере. Градиент задан у нуля (от -edgeWidth до 0),
    // а при рисовании холст сдвигается на положение края, так что шейдер едет вместе с ним
    final edge = make(style.copyWith(
      foreground: Paint()..shader = ui.Gradient.linear(Offset(-edgeWidth, 0), Offset.zero, [Colors.white, const Color(0x00FFFFFF)]),
    ));
    final boxes = <List<Rect>>[];
    var end = Duration.zero;
    for (final w in words) {
      if (w.end > end) end = w.end;
      if (w.start > end) end = w.start;
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
    return _Layout(dim, bright, glow, edge, boxes, bright.height, fontSize, edgeWidth, end);
  }

  void dispose() {
    dim.dispose();
    bright.dispose();
    glow.dispose();
    edge.dispose();
    finished?.dispose();
    finished = null;
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
    // Строка спета целиком: рисуем записанную картинку, ничего не пересчитывая
    if (words.isNotEmpty && t >= l.endAll) {
      canvas.drawPicture(l.finished ??= _record());
      WidgetsBinding.instance.addPostFrameCallback((_) => onDone());
      return;
    }
    l.dim.paint(canvas, Offset.zero);
    // Все целиком спетые слова и их твёрдая часть — в один путь: один clipPath и одна отрисовка яркого текста
    final bright = Path();
    final glowArea = Path(); // целиком спетое — для свечения
    final soft = <Rect>[]; // мягкий край у слова, которое поют сейчас
    var hasBright = false, hasGlow = false;
    for (var k = 0; k < words.length; k++) {
      final w = words[k];
      final f = w.end <= w.start ? (t >= w.start ? 1.0 : 0.0) : ((t - w.start).inMilliseconds / (w.end - w.start).inMilliseconds).clamp(0.0, 1.0);
      if (f <= 0) continue;
      final boxes = l.wordBoxes[k];
      var left = boxes.fold<double>(0, (a, b) => a + b.width) * f;
      for (final r in boxes) {
        if (left <= 0) break;
        final bw = math.min(left, r.width);
        left -= r.width;
        if (bw >= r.width - 0.5) {
          bright.addRect(r);
          glowArea.addRect(r.inflate(2));
          hasBright = hasGlow = true;
        } else {
          final x = r.left + bw;
          final solidTo = x - l.edgeWidth;
          if (solidTo > r.left) {
            bright.addRect(Rect.fromLTRB(r.left, r.top, solidTo, r.bottom));
            hasBright = true;
          }
          soft.add(Rect.fromLTRB(math.max(r.left, solidTo), r.top, x, r.bottom));
        }
      }
    }
    if (hasBright) {
      canvas.save();
      canvas.clipPath(bright);
      l.bright.paint(canvas, Offset.zero);
      canvas.restore();
    }
    for (final r in soft) {
      if (r.width <= 0) continue;
      canvas.save();
      canvas.clipRect(r);
      canvas.translate(r.right, 0);
      l.edge.paint(canvas, Offset(-r.right, 0));
      canvas.restore();
    }
    // К1: спетое слегка светится
    if (hasGlow) {
      canvas.save();
      canvas.clipPath(glowArea);
      l.glow.paint(canvas, Offset.zero);
      canvas.restore();
    }
  }

  /// Полностью спетая строка, записанная в картинку: тусклый текст, яркие слова и свечение
  ui.Picture _record() {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    l.dim.paint(c, Offset.zero);
    final bright = Path(), glowArea = Path();
    for (final boxes in l.wordBoxes) {
      for (final r in boxes) {
        bright.addRect(r);
        glowArea.addRect(r.inflate(2));
      }
    }
    c.save();
    c.clipPath(bright);
    l.bright.paint(c, Offset.zero);
    c.restore();
    c.save();
    c.clipPath(glowArea);
    l.glow.paint(c, Offset.zero);
    c.restore();
    return rec.endRecording();
  }

  @override
  bool shouldRepaint(_KaraokePainter old) => !identical(old.l, l) || old.words != words;
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

