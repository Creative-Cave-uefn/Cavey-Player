import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/smooth_position.dart';
import '../core/player.dart';
import 'cinema_view.dart';
import 'shell.dart';
import 'theme.dart';
import 'tracks_view.dart';
import 'widgets.dart';

/// Предпросмотр времени при перетаскивании по полосе перемотки: осветление в капсуле идёт за курсором
final _seekPreview = ValueNotifier<Duration?>(null);

/// Отступ у краёв капсулы, где она закругляется: полоса перемотки идёт по прямому участку верхней грани
const _capInset = 38.0;

class PlayerBar extends StatelessWidget {
  final bool compact;
  const PlayerBar({super.key, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final p = app.player;
    return _SeekGestures(
      player: p,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: SizedBox(
          height: 76,
          child: Stack(clipBehavior: Clip.none, children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(38), border: Border.all(color: C.line)),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(37),
                  child: Stack(children: [
                    // Прослушанная часть — мягкое осветление фона капсулы
                    Positioned.fill(child: _Wash(player: p)),
                    Positioned.fill(child: _content(context, app)),
                  ]),
                ),
              ),
            ),
            // Перемотка: вся ровная верхняя грань капсулы. Время появляется, когда на неё наводят мышь
            Positioned(left: _capInset, right: _capInset, top: 0, height: 14, child: _TopSeek(player: p)),
          ]),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, AppServices app) {
    final p = app.player;
    return ListenableBuilder(
      listenable: Listenable.merge([p, app.lib, app.wave]),
      builder: (context, _) {
        final t = p.current;
        const ink = C.text;

        final controls = Row(mainAxisSize: MainAxisSize.min, children: [
          if (!compact)
            IconButton(
              tooltip: p.shuffle ? 'Выключить перемешивание' : 'Перемешать',
              onPressed: p.toggleShuffle,
              icon: Icon(Icons.shuffle_rounded, size: 20, color: p.shuffle ? C.accent : C.muted),
            ),
          IconButton(
            tooltip: 'Предыдущий',
            onPressed: t == null ? null : p.previous,
            icon: const Icon(Icons.fast_rewind_rounded, size: 30, color: ink),
          ),
          SizedBox.square(
            dimension: 48,
            child: p.buffering && t != null
                ? const Padding(padding: EdgeInsets.all(13), child: CircularProgressIndicator(strokeWidth: 2.5, color: ink))
                : IconButton(
                    tooltip: p.playing ? 'Пауза' : 'Играть',
                    onPressed: t == null ? null : p.toggle,
                    icon: Icon(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 36, color: ink),
                  ),
          ),
          IconButton(
            tooltip: 'Следующий',
            onPressed: t == null ? null : p.next,
            icon: const Icon(Icons.fast_forward_rounded, size: 30, color: ink),
          ),
          if (!compact)
            IconButton(
              tooltip: switch (p.repeat) {
                RepeatSetting.off => 'Повторять всё',
                RepeatSetting.all => 'Повторять трек',
                RepeatSetting.one => 'Не повторять',
              },
              onPressed: p.cycleRepeat,
              icon: Icon(
                p.repeat == RepeatSetting.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                size: 20,
                color: p.repeat == RepeatSetting.off ? C.muted : C.accent,
              ),
            ),
        ]);

        // Слева без плашки: обложка у самого края капсулы, чуть крупнее и будто выглядывает из-за неё —
        // правая грань размыта и плавно уходит в фон. Рядом название и исполнитель
        final card = t == null
            ? const Padding(
                padding: EdgeInsets.only(left: 26),
                child: Align(alignment: Alignment.centerLeft, child: Text('Выберите трек', style: TextStyle(color: C.faint))),
              )
            : Row(children: [
                Tooltip(
                  message: 'Открыть альбом',
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => NavScope.of(context).go(Nav('album', t.albumKey)),
                      child: ShaderMask(
                        // Правая часть обложки растворяется
                        shaderCallback: (r) => const LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [Colors.white, Colors.white, Color(0x00FFFFFF)],
                          stops: [0.0, 0.58, 1.0],
                        ).createShader(r),
                        blendMode: BlendMode.dstIn,
                        child: CoverImage(track: t, size: 104, height: 74, radius: 0, fill: true),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Expanded(
                  // Правый клик по названию и исполнителю — полное меню трека (без «Выбрать»); обычный клик по ссылке работает как раньше
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onSecondaryTapUp: (d) => showTrackMenu(context, t, null, d.globalPosition, openPlaylist: p.sourcePlaylist),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      // Название ведёт в альбом, как и обложка
                      Links(
                        parts: [LinkPart(t.title, () => NavScope.of(context).go(Nav('album', t.albumKey)))],
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                      const SizedBox(height: 2),
                      Links(parts: trackLinks(context, t, album: true), style: const TextStyle(color: C.muted, fontSize: 13)),
                    ]),
                  ),
                ),
                if (app.wave.active) ...[
                  IconButton(
                    tooltip: app.wave.isUpvoted(t.id)
                        ? 'Нравится в волне — нажмите, чтобы отменить'
                        : 'Нравится в волне: больше похожего, но без сохранения в любимое',
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    onPressed: app.wave.upvote,
                    icon: Icon(app.wave.isUpvoted(t.id) ? Icons.thumb_up_alt_rounded : Icons.thumb_up_alt_outlined,
                        color: app.wave.isUpvoted(t.id) ? C.accent : C.muted),
                  ),
                  IconButton(
                    tooltip: 'Не нравится — больше не ставить в волне',
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    onPressed: app.wave.dislike,
                    icon: const Icon(Icons.thumb_down_alt_outlined, color: C.muted),
                  ),
                ],
                LikeButton(track: t),
                const SizedBox(width: 4),
              ]);

        final lyricsButton = ValueListenableBuilder<bool>(
          valueListenable: p.lyricsOpen,
          builder: (context, open, _) => IconButton(
            tooltip: open ? 'Скрыть текст песни' : 'Текст песни',
            onPressed: p.toggleLyricsPanel,
            icon: Icon(Icons.lyrics_outlined, color: open ? C.accent : ink),
          ),
        );
        final queueButton = ValueListenableBuilder<bool>(
          valueListenable: p.queueOpen,
          builder: (context, open, _) => IconButton(
            tooltip: open ? 'Скрыть очередь' : 'Очередь',
            onPressed: t == null ? null : p.toggleQueuePanel,
            icon: Icon(Icons.queue_music_rounded, color: open ? C.accent : ink),
          ),
        );

        if (compact) {
          return Row(children: [
            Expanded(child: card),
            const SizedBox(width: 6),
            controls,
            lyricsButton,
            queueButton,
            const SizedBox(width: 8),
          ]);
        }
        // Слева карточка трека, ровно по центру — кнопки, справа: текст, очередь, громкость, кинотеатр.
        // Боковые части одинаковой ширины, поэтому кнопки стоят точно посередине капсулы
        return Row(children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: card),
            ),
          ),
          const SizedBox(width: 12),
          controls,
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    lyricsButton,
                    queueButton,
                    _VolumeControl(p),
                    const SizedBox(width: 4),
                    const CinemaButton(),
                  ]),
                ),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

/// Горизонтальные жесты над нижней панелью: наклон колеса и свайп двумя пальцами по тачпаду перематывают на 10 секунд
class _SeekGestures extends StatefulWidget {
  final PlayerController player;
  final Widget child;
  const _SeekGestures({required this.player, required this.child});
  @override
  State<_SeekGestures> createState() => _SeekGesturesState();
}

class _SeekGesturesState extends State<_SeekGestures> {
  static const _step = Duration(seconds: 10);
  static const _panStep = 80.0; // сколько пикселей свайпа даёт один шаг
  double _pan = 0;

  void _seek(int dir) => widget.player.seekBy(_step * dir);

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (e) {
        if (e is! PointerScrollEvent) return;
        if (e.scrollDelta.dx.abs() > e.scrollDelta.dy.abs() && e.scrollDelta.dx != 0) _seek(e.scrollDelta.dx > 0 ? 1 : -1);
      },
      onPointerPanZoomStart: (_) => _pan = 0,
      onPointerPanZoomUpdate: (e) {
        if (e.panDelta.dx.abs() <= e.panDelta.dy.abs()) return;
        _pan += e.panDelta.dx;
        while (_pan.abs() >= _panStep) {
          final dir = _pan > 0 ? 1 : -1;
          _pan -= _panStep * dir;
          _seek(dir);
        }
      },
      child: widget.child,
    );
  }
}

/// Какой край у осветления прослушанной части: false — прямая линия, true — бегущая волна.
/// Меняется в «Настройки → Внешний вид»
final seekEdgeWave = ValueNotifier<bool>(false);

/// Длина волны края (период по вертикали, px): 8 — частая рябь, 40 — плавные длинные изгибы
final seekWaveLength = ValueNotifier<double>(18);

/// Шкала длины волны: короче 17 нельзя (дальше влево — перебор), вправо добавлена длинная волна
const seekWaveMin = 17.0, seekWaveMax = 60.0;

/// Осветление капсулы по прослушанной части: слева направо до текущего места
class _Wash extends StatefulWidget {
  final PlayerController player;
  const _Wash({required this.player});

  @override
  State<_Wash> createState() => _WashState();
}

class _WashState extends State<_Wash> with SingleTickerProviderStateMixin {
  // Волна медленно течёт по вертикали; один оборот — две секунды
  late final AnimationController _flow = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
  bool _init = false;

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_sync);
    seekEdgeWave.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_init) {
      _init = true;
      final st = Services.of(context).settings;
      seekEdgeWave.value = st.viewOf('seek.edge', 'straight') == 'wave';
      seekWaveLength.value = st.viewNum('seek.wlen', 18).clamp(seekWaveMin, seekWaveMax).toDouble();
      _sync();
    }
  }

  @override
  void dispose() {
    widget.player.removeListener(_sync);
    seekEdgeWave.removeListener(_sync);
    _flow.dispose();
    super.dispose();
  }

  /// Тикер крутится, только пока волна включена и музыка играет: на паузе волна замирает и ничего не тратит
  void _sync() {
    final run = seekEdgeWave.value && widget.player.playing;
    if (run && !_flow.isAnimating) {
      _flow.repeat();
    } else if (!run && _flow.isAnimating) {
      _flow.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      return ListenableBuilder(
        listenable: Listenable.merge([SmoothPosition.of(player), _seekPreview, seekEdgeWave, seekWaveLength, player.fadeInfo]),
        builder: (context, _) {
          final total = player.duration.inMilliseconds.toDouble();
          final at = (_seekPreview.value ?? SmoothPosition.of(player).value).inMilliseconds.toDouble();
          final f = total <= 0 ? 0.0 : (at / total).clamp(0.0, 1.0);
          // Полоса перемотки идёт по прямому участку грани, а осветление — от самого края капсулы
          double xOf(double fr) => fr <= 0 ? 0.0 : (fr >= 1 ? w : _capInset + fr * (w - 2 * _capInset));
          final x = xOf(f);
          // Плавный переход: полоса уходящего трека доезжает до края и гаснет, а слева уже растёт полоса нового
          final info = player.fadeInfo.value;
          double fadeX = 0, fadeAlpha = 0;
          if (info != null) {
            final t = Curves.easeInOut.transform(info.progress(DateTime.now()));
            fadeX = xOf(info.fromFraction + (1 - info.fromFraction) * t);
            fadeAlpha = 1 - t;
          }
          return RepaintBoundary(
            child: CustomPaint(
              size: Size(w, box.maxHeight),
              painter: _WashPainter(
                  x: x, wave: seekEdgeWave.value, length: seekWaveLength.value, flow: _flow, fadeX: fadeX, fadeAlpha: fadeAlpha),
            ),
          );
        },
      );
    });
  }
}

/// Рисует осветление до [x]; правая граница — прямая или синусоида, бегущая вдоль неё.
/// Во время плавного перехода под ним рисуется полоса уходящего трека до [fadeX] с прозрачностью [fadeAlpha]
class _WashPainter extends CustomPainter {
  final double x;
  final bool wave;
  final double length;
  final Animation<double> flow;
  final double fadeX;
  final double fadeAlpha;
  _WashPainter({required this.x, required this.wave, required this.length, required this.flow, this.fadeX = 0, this.fadeAlpha = 0})
      : super(repaint: flow);

  static const amplitude = 3.0;

  void _strip(Canvas canvas, Size size, double x, double alpha) {
    if (x <= 0 || alpha <= 0) return;
    final rect = Rect.fromLTWH(0, 0, x, size.height);
    final paint = Paint()
      ..shader = LinearGradient(colors: [
        Color.fromRGBO(255, 255, 255, 0.04 * alpha),
        Color.fromRGBO(255, 255, 255, 0.10 * alpha),
      ]).createShader(rect);
    // Дошли до конца трека — края уже не видно
    if (!wave || x >= size.width - 0.5) {
      canvas.drawRect(rect, paint);
      return;
    }
    final phase = flow.value * 2 * math.pi;
    final path = Path()..moveTo(0, 0);
    for (var y = 0.0; y <= size.height + 1; y += 1.5) {
      path.lineTo(x + amplitude * math.sin(y / length * 2 * math.pi - phase), y);
    }
    path
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    _strip(canvas, size, fadeX, fadeAlpha);
    _strip(canvas, size, x, 1);
  }

  @override
  bool shouldRepaint(_WashPainter old) =>
      old.x != x || old.wave != wave || old.length != length || old.fadeX != fadeX || old.fadeAlpha != fadeAlpha;
}

/// Маленький пример края для «Настроек»: полоска осветления с прямой или волнистой границей
class SeekEdgeSample extends StatefulWidget {
  final bool wave;
  const SeekEdgeSample({super.key, required this.wave});

  @override
  State<SeekEdgeSample> createState() => _SeekEdgeSampleState();
}

class _SeekEdgeSampleState extends State<SeekEdgeSample> with SingleTickerProviderStateMixin {
  late final AnimationController _flow = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void initState() {
    super.initState();
    if (widget.wave) _flow.repeat();
  }

  @override
  void didUpdateWidget(SeekEdgeSample old) {
    super.didUpdateWidget(old);
    if (widget.wave && !_flow.isAnimating) _flow.repeat();
    if (!widget.wave) _flow.stop();
  }

  @override
  void dispose() {
    _flow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 120,
      height: 40,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: C.line)),
      child: ValueListenableBuilder<double>(
        valueListenable: seekWaveLength,
        builder: (context, len, _) => CustomPaint(painter: _WashPainter(x: 62, wave: widget.wave, length: len, flow: _flow)),
      ),
    );
  }
}

/// Перемотка по верхней грани капсулы: клик и перетаскивание. Пока мышь над полосой — тонкая линия,
/// метка под курсором, слева сколько прошло, справа сколько всего
class _TopSeek extends StatefulWidget {
  final PlayerController player;
  const _TopSeek({required this.player});
  @override
  State<_TopSeek> createState() => _TopSeekState();
}

class _TopSeekState extends State<_TopSeek> {
  double? _drag; // миллисекунды
  double? _hoverX;

  @override
  void dispose() {
    _seekPreview.value = null;
    super.dispose();
  }

  void _seekTo(double dx, double width, {bool commit = false}) {
    final total = widget.player.duration.inMilliseconds.toDouble();
    if (total <= 0 || width <= 0) return;
    final v = (dx / width).clamp(0.0, 1.0) * total;
    if (commit) {
      setState(() => _drag = null);
      _seekPreview.value = null;
      widget.player.seek(Duration(milliseconds: v.round()));
    } else {
      setState(() => _drag = v);
      _seekPreview.value = Duration(milliseconds: v.round());
    }
  }

  static Widget _label(String text) => DecoratedBox(
        decoration: BoxDecoration(color: const Color(0xB3000000), borderRadius: BorderRadius.circular(8)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          child: Text(text,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()], decoration: TextDecoration.none)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      return Listener(
        // Колесо над полосой: ±5 секунд за щелчок, с Shift ±1 секунда
        onPointerSignal: (e) {
          if (e is! PointerScrollEvent || p.current == null) return;
          if (e.scrollDelta.dy.abs() <= e.scrollDelta.dx.abs() || e.scrollDelta.dy == 0) return;
          final shift = HardwareKeyboard.instance.isShiftPressed;
          p.seekBy(Duration(seconds: shift ? 1 : 5) * (e.scrollDelta.dy < 0 ? 1 : -1));
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onHover: (e) => setState(() => _hoverX = e.localPosition.dx.clamp(0.0, w).toDouble()),
          onExit: (_) => setState(() => _hoverX = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _seekTo(d.localPosition.dx, w, commit: true),
            onHorizontalDragUpdate: (d) {
              _hoverX = d.localPosition.dx.clamp(0.0, w).toDouble();
              _seekTo(d.localPosition.dx, w);
            },
            onHorizontalDragEnd: (_) {
              final v = _drag;
              if (v == null) return;
              setState(() => _drag = null);
              _seekPreview.value = null;
              p.seek(Duration(milliseconds: v.round()));
            },
            child: ValueListenableBuilder<Duration>(
              valueListenable: SmoothPosition.of(p),
              builder: (context, pos, _) {
                final total = p.duration.inMilliseconds.toDouble();
                final value = _drag ?? pos.inMilliseconds.toDouble();
                final f = total <= 0 ? 0.0 : (value / total).clamp(0.0, 1.0);
                final on = (_hoverX != null || _drag != null) && p.current != null;
                final hx = _hoverX;
                final hoverMs = hx == null || total <= 0 ? null : (hx / w).clamp(0.0, 1.0) * total;
                // Точка — текущее место в треке; облачко с временем едет вместе с ней
                final dotX = f * w;
                // Метка под курсором: если она налезает на облачко точки, виден только тот, что под курсором
                final showMark = hx != null && hoverMs != null && (hx - dotX).abs() > 8;
                final overlaps = showMark && (hx - dotX).abs() < 56;
                final nearEnd = dotX > w - 54 || (showMark && hx > w - 54);
                return Stack(clipBehavior: Clip.none, children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 1,
                    height: 4,
                    child: AnimatedOpacity(
                      opacity: on ? 1 : 0,
                      duration: const Duration(milliseconds: 120),
                      // Скруглённые концы: радиус — половина толщины
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: Stack(children: [
                          const Positioned.fill(child: ColoredBox(color: Color(0x33FFFFFF))),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(widthFactor: f, heightFactor: 1, child: const ColoredBox(color: Color(0xE6FFFFFF))),
                          ),
                        ]),
                      ),
                    ),
                  ),
                  if (on && hx != null)
                    Positioned(
                      left: hx - 1,
                      top: 0,
                      width: 2,
                      height: 14,
                      child: DecoratedBox(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(1))),
                    ),
                  if (on) ...[
                    Positioned(
                      left: dotX - 5,
                      top: -3,
                      width: 10,
                      height: 10,
                      child: const IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle))),
                    ),
                    if (!overlaps)
                      Positioned(
                        left: dotX - 30,
                        top: -30,
                        width: 60,
                        child: IgnorePointer(child: Center(child: _label(formatDuration(Duration(milliseconds: value.round()))))),
                      ),
                    if (!nearEnd)
                      Positioned(
                        right: 0,
                        top: -30,
                        child: IgnorePointer(child: _label(formatDuration(p.duration))),
                      ),
                    if (showMark)
                      Positioned(
                        left: hx - 30,
                        top: -30,
                        width: 60,
                        child: IgnorePointer(child: Center(child: _label(formatDuration(Duration(milliseconds: hoverMs!.round()))))),
                      ),
                  ],
                ]);
              },
            ),
          ),
        ),
      );
    });
  }
}

/// Колесо мыши над [child] меняет громкость: на 5 %, с Shift на 1 %. Ползунок доезжает до цели короткой анимацией.
/// [builder] получает функцию, которую надо вызвать, когда человек берётся за ползунок сам
class VolumeWheel extends StatefulWidget {
  final PlayerController p;
  final Widget Function(BuildContext context, VoidCallback stopAnim) builder;
  const VolumeWheel({super.key, required this.p, required this.builder});

  @override
  State<VolumeWheel> createState() => _VolumeWheelState();
}

class _VolumeWheelState extends State<VolumeWheel> with SingleTickerProviderStateMixin {
  double _acc = 0;
  Timer? _save;

  // Колесо двигает громкость плавно: ползунок доезжает до цели за короткую анимацию, а не прыгает
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))..addListener(_tick);
  double _from = 0;
  double? _to;

  @override
  void dispose() {
    _save?.cancel();
    _anim.dispose();
    super.dispose();
  }

  void _tick() {
    final to = _to;
    if (to == null) return;
    final v = _from + (to - _from) * Curves.easeOutCubic.transform(_anim.value);
    widget.p.setVolume(v);
  }

  void _onScroll(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (_) {
      final p = widget.p;
      final step = HardwareKeyboard.instance.isShiftPressed ? 1.0 : 5.0;
      // Вверх (отрицательный dy) — громче. Мелкую прокрутку тачпада копим, пока не наберётся целый процент
      _acc += -e.scrollDelta.dy / 100 * step;
      final whole = _acc.truncate();
      if (whole == 0) return;
      _acc -= whole;
      // Цель считаем от прежней цели: быстрые щелчки колеса складываются, а не теряются по пути
      final v = ((_anim.isAnimating ? (_to ?? p.volume) : p.volume) + whole).clamp(0, 100).toDouble();
      _from = p.volume;
      _to = v;
      _anim.forward(from: 0);
      _save?.cancel();
      _save = Timer(const Duration(milliseconds: 600), () => p.setVolume(v, save: true));
    });
  }

  /// Пользователь взялся за ползунок сам — колёсная анимация больше не тянет громкость к своей цели
  void _stopAnim() {
    _to = null;
    _anim.stop();
    _save?.cancel();
  }

  @override
  Widget build(BuildContext context) => Listener(onPointerSignal: _onScroll, child: widget.builder(context, _stopAnim));
}

/// Динамик и ползунок громкости. Колесо мыши над ними меняет громкость: на 5 %, с Shift на 1 %.
class _VolumeControl extends StatelessWidget {
  final PlayerController p;
  const _VolumeControl(this.p);

  @override
  Widget build(BuildContext context) {
    return VolumeWheel(
      p: p,
      builder: (context, stop) => Row(mainAxisSize: MainAxisSize.min, children: [
        // Клик по динамику — выключить звук, ещё клик — вернуть прежнюю громкость
        IconButton(
          tooltip: p.volume == 0 ? 'Включить звук' : 'Выключить звук',
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          onPressed: () {
            stop();
            p.toggleMute();
          },
          icon: Icon(
            p.volume == 0
                ? Icons.volume_off_rounded
                : (p.volume < 40 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
            color: p.volume == 0 ? C.muted : C.text,
          ),
        ),
        SizedBox(
          width: 120,
          child: Slider(
            value: p.volume.clamp(0.0, 100.0).toDouble(),
            max: 100,
            onChangeStart: (_) => stop(),
            onChanged: (v) => p.setVolume(v),
            onChangeEnd: (v) => p.setVolume(v, save: true),
          ),
        ),
      ]),
    );
  }
}
