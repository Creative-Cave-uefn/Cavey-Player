import 'package:flutter/material.dart';

import '../app.dart';
import '../core/smooth_position.dart';
import '../core/models.dart';
import '../core/player.dart';
import 'ambient.dart';
import 'lyrics_panel.dart';
import 'shell.dart';
import 'player_bar.dart' show VolumeWheel;
import 'theme.dart';
import 'tracks_view.dart';
import 'widgets.dart';

/// Режим кинотеатра в духе Apple Music: «живой» фон из обложки на всё окно, слева обложка
/// и управление, справа крупный текст с караоке. Боковая панель и плеер здесь не выезжают —
/// всё управление на самой странице
class CinemaPage extends StatefulWidget {
  final bool compact;
  const CinemaPage({super.key, required this.compact});

  @override
  State<CinemaPage> createState() => _CinemaPageState();
}

class _CinemaPageState extends State<CinemaPage> {
  /// Текст включён человеком (кнопка внизу справа)
  bool _lyrics = true;

  /// Есть ли у текущего трека текст, который можно показать. Колонка текста появляется только
  /// когда текст найден; пока он ищется, остаётся прежнее решение (при входе — «нет»), а «не нашёлся»,
  /// «инструментал» и «база не отвечает» никогда не рисуют окно поиска справа — об этом говорит подсказка у кнопки
  bool _found = false;
  String? _foundFor;
  String? _asked;

  /// Подсказка «Текст не найден» над кнопкой
  bool _hint = false;

  /// 'found' | 'loading' | 'none' | 'failed'
  String _state(Track t) {
    final lyr = Services.of(context).lyrics;
    if (_foundFor != t.id) {
      _foundFor = t.id;
      _hint = false;
    }
    if (lyr.known(t)) {
      final l = lyr.cached(t);
      _found = l != null && !l.instrumental && l.lines.isNotEmpty;
      return _found ? 'found' : 'none';
    }
    if (lyr.failed(t) && !lyr.loading(t)) {
      _found = false;
      return 'failed';
    }
    return 'loading';
  }

  /// Поиск обычно уже начат плеером; если нет — начинаем, чтобы узнать ответ и со скрытой панелью текста
  void _ask(Track t, {bool refresh = false}) {
    if (!refresh && _asked == t.id) return;
    _asked = t.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final app = Services.of(context);
      if (!refresh && (app.lyrics.known(t) || app.lyrics.loading(t))) return;
      app.lyrics.forTrack(t, app.player.duration, refresh: refresh).then<void>((_) {}, onError: (Object _) {});
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => AmbientScope.vivid.value = true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.addPostFrameCallback((_) => AmbientScope.vivid.value = false);
    super.dispose();
  }

  void _close() {
    final nav = NavScope.of(context);
    nav.canBack ? nav.back() : nav.go(const Nav('wave'));
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final p = app.player;
    return ListenableBuilder(
      listenable: Listenable.merge([p, app.lib, app.lyrics]),
      builder: (context, _) {
        final t = p.current;
        if (t != null) _ask(t);
        final state = t == null ? 'loading' : _state(t);
        final none = state == 'none' || state == 'failed';
        final showLyrics = _lyrics && _found;
        return Stack(children: [
          if (t == null)
            const EmptyState(
              icon: Icons.theaters_rounded,
              title: 'Ничего не играет',
              text: 'Включите трек — здесь будет его обложка и текст во весь экран.',
            )
          else
            LayoutBuilder(builder: (context, box) {
              final narrow = box.maxWidth < 900;
              final sideW = narrow ? box.maxWidth : box.maxWidth * 0.46;
              final maxCover = (box.maxHeight - 330).clamp(160.0, 560.0);
              // Обложка в двух раскладках: по центру окна и в левой части рядом с текстом
              final coverSplit = (narrow ? box.maxHeight * 0.34 : sideW - 120).clamp(160.0, maxCover).toDouble();
              final coverCentered = (box.maxWidth - 120).clamp(160.0, maxCover).toDouble();
              return TweenAnimationBuilder<double>(
                tween: Tween(end: showLyrics ? 1.0 : 0.0),
                duration: const Duration(milliseconds: 480),
                curve: Curves.easeInOutCubic,
                builder: (context, k, _) {
                  final cover = coverCentered + (coverSplit - coverCentered) * k;
                  final left = NowPanel(width: cover);
                  Widget? lyrics;
                  if (k > 0.001) {
                    lyrics = ShaderMask(
                      // Текст растворяется у верхнего и нижнего края, как в Apple Music
                      shaderCallback: (r) => const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
                        stops: [0.0, 0.18, 0.82, 1.0],
                      ).createShader(r),
                      blendMode: BlendMode.dstIn,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(narrow ? 32 : 24, 0, narrow ? 32 : 96, 0),
                        child: LyricsBody(key: ValueKey(t.id), track: t, big: true, karaoke: true),
                      ),
                    );
                    lyrics = IgnorePointer(
                      ignoring: k < 0.6,
                      child: Opacity(opacity: k.clamp(0.0, 1.0), child: Transform.translate(offset: Offset((1 - k) * 60, 0), child: lyrics)),
                    );
                  }
                  if (narrow) {
                    // Узкое окно: обложка уезжает из центра вверх, текст проявляется под ней
                    final top = 56 + coverSplit + 215;
                    return Stack(children: [
                      Positioned.fill(
                        child: Align(
                          alignment: Alignment(0, -k),
                          child: Padding(padding: EdgeInsets.only(top: 56 * k), child: left),
                        ),
                      ),
                      if (lyrics != null) Positioned(left: 0, right: 0, top: top, bottom: 0, child: lyrics),
                    ]);
                  }
                  final leftW = box.maxWidth + (sideW - box.maxWidth) * k;
                  return Stack(children: [
                    Positioned(left: 0, top: 0, bottom: 0, width: leftW, child: Center(child: left)),
                    if (lyrics != null) Positioned(left: sideW, right: 0, top: 0, bottom: 0, child: lyrics),
                  ]);
                },
              );
            }),
          // Подсказка, если у трека нет текста
          if (t != null && none && _hint)
            Positioned(
              right: 23,
              bottom: 80,
              child: Material(
                color: C.glassLight,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 10, 8),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(state == 'failed' ? 'База текстов не отвечает' : 'Текст не найден', style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    TextButton.icon(
                      onPressed: () {
                        setState(() => _hint = false);
                        _ask(t, refresh: true);
                      },
                      icon: const Icon(Icons.search_rounded, size: 18),
                      label: const Text('Найти текст'),
                    ),
                  ]),
                ),
              ),
            ),
          // Выход — там же, где в плеере кнопка входа; левее него — кнопка текста. Обе приглушены, чтобы не бросались в глаза
          Positioned(
            right: 23,
            bottom: 24,
            child: IconButton(
              tooltip: 'Выйти из кинотеатра (Esc)',
              onPressed: _close,
              icon: Icon(Icons.fullscreen_exit_rounded, size: 26, color: C.text.withValues(alpha: 0.55)),
            ),
          ),
          Positioned(
            right: 23 + 48 + 4,
            bottom: 24,
            child: IconButton(
              tooltip: none
                  ? 'Текст не найден'
                  : (state == 'loading' && !_found ? 'Ищем текст…' : (_lyrics ? 'Скрыть текст' : 'Показать текст')),
              onPressed: none ? () => setState(() => _hint = !_hint) : () => setState(() => _lyrics = !_lyrics),
              icon: Icon(Icons.lyrics_outlined, color: showLyrics ? C.text.withValues(alpha: 0.55) : C.text.withValues(alpha: 0.28)),
            ),
          ),
        ]);
      },
    );
  }
}

/// Обложка, название, перемотка, управление и громкость — колонкой, как в Apple Music
class NowPanel extends StatelessWidget {
  final double width;

  /// Вместо перемешивания и повтора по краям кнопок управления (в «Моей волне» — «не нравится» / «нравится»)
  final Widget? leftAction, rightAction;

  /// Подпись под названием (в «Моей волне» — почему выбран этот трек)
  final String? caption;
  const NowPanel({super.key, required this.width, this.leftAction, this.rightAction, this.caption});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final t = app.player.current!;
    final liked = app.lib.isLiked(t.id);
    return SizedBox(
      width: width,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 50, offset: Offset(0, 22))],
          ),
          child: CoverImage(track: t, size: width, radius: 14, fullscreen: true),
        ),
        const SizedBox(height: 22),
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Links(parts: trackLinks(context, t, album: true), style: const TextStyle(color: C.muted, fontSize: 15, fontWeight: FontWeight.w600)),
              if (caption != null && caption!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(caption!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.faint, fontSize: 12)),
                ),
            ]),
          ),
          _Round(
            tooltip: liked ? 'Убрать из любимого' : 'В любимое',
            icon: liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            color: liked ? C.accent : C.text,
            onTap: () => app.lib.toggleLike(t.id),
          ),
          const SizedBox(width: 10),
          SizedBox.square(dimension: 34, child: Center(child: TrackMenu(track: t, openPlaylist: Services.of(context).player.sourcePlaylist))),
        ]),
        const SizedBox(height: 18),
        NowControls(leftAction: leftAction, rightAction: rightAction),
      ]),
    );
  }
}

/// Перемотка, кнопки управления и громкость: нижняя часть плеера в кинотеатре и в «Моей волне»
class NowControls extends StatelessWidget {
  /// Вместо перемешивания и повтора по краям кнопок управления
  final Widget? leftAction, rightAction;
  const NowControls({super.key, this.leftAction, this.rightAction});

  @override
  Widget build(BuildContext context) {
    final p = Services.of(context).player;
    // Колесо над всем блоком управления меняет громкость (плавно, как в основном плеере)
    return VolumeWheel(p: p, builder: (context, stop) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Seek(player: p),
        const SizedBox(height: 12),
        // Кнопки сжимаются под ширину обложки, а не вылезают вправо: иначе «Играть» уезжает от центра
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
          leftAction ??
              IconButton(
                tooltip: p.shuffle ? 'Выключить перемешивание' : 'Перемешать',
                onPressed: p.toggleShuffle,
                icon: Icon(Icons.shuffle_rounded, size: 22, color: p.shuffle ? C.accent : C.muted),
              ),
          const SizedBox(width: 18),
          IconButton(onPressed: p.previous, tooltip: 'Предыдущий', icon: const Icon(Icons.fast_rewind_rounded, size: 42, color: C.text)),
          const SizedBox(width: 10),
          IconButton(
            onPressed: p.toggle,
            tooltip: p.playing ? 'Пауза' : 'Играть',
            icon: Icon(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 54, color: C.text),
          ),
          const SizedBox(width: 10),
          IconButton(onPressed: p.next, tooltip: 'Следующий', icon: const Icon(Icons.fast_forward_rounded, size: 42, color: C.text)),
          const SizedBox(width: 18),
          rightAction ??
              IconButton(
                tooltip: 'Повтор',
                onPressed: p.cycleRepeat,
                icon: Icon(p.repeat == RepeatSetting.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                    size: 22, color: p.repeat == RepeatSetting.off ? C.muted : C.accent),
              ),
        ]),
        ),
        const SizedBox(height: 12),
        Row(children: [
          const Icon(Icons.volume_down_rounded, size: 20, color: C.muted),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(trackHeight: 4, activeTrackColor: C.text, inactiveTrackColor: const Color(0x40FFFFFF)),
              child: Slider(
                value: p.volume.clamp(0.0, 100.0).toDouble(),
                max: 100,
                onChangeStart: (_) => stop(),
                onChanged: (v) => p.setVolume(v),
                onChangeEnd: (v) => p.setVolume(v, save: true),
              ),
            ),
          ),
          const Icon(Icons.volume_up_rounded, size: 20, color: C.muted),
        ]),
    ]));
  }
}

class _Round extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _Round({required this.tooltip, required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: const Color(0x26FFFFFF),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox.square(dimension: 34, child: Icon(icon, size: 20, color: color)),
          ),
        ),
      );
}

/// Перемотка: тонкая полоса, под ней прошло и осталось
class _Seek extends StatefulWidget {
  final PlayerController player;
  const _Seek({required this.player});

  @override
  State<_Seek> createState() => _SeekState();
}

class _SeekState extends State<_Seek> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    const time = TextStyle(color: C.muted, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]);
    return ValueListenableBuilder<Duration>(
      valueListenable: SmoothPosition.of(p),
      builder: (context, pos, _) {
        final total = p.duration.inMilliseconds.toDouble();
        final v = (_drag ?? pos.inMilliseconds.toDouble()).clamp(0.0, total <= 0 ? 1.0 : total).toDouble();
        return Column(children: [
          SizedBox(
            height: 22,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                activeTrackColor: C.text,
                inactiveTrackColor: const Color(0x40FFFFFF),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                value: v,
                max: total <= 0 ? 1.0 : total,
                onChanged: total <= 0 ? null : (x) => setState(() => _drag = x),
                onChangeEnd: (x) async {
                  await p.seek(Duration(milliseconds: x.round()));
                  if (mounted) setState(() => _drag = null);
                },
              ),
            ),
          ),
          Row(children: [
            Text(formatDuration(Duration(milliseconds: v.round())), style: time),
            const Spacer(),
            Text('−${formatDuration(Duration(milliseconds: (total - v).round().clamp(0, 1 << 31)))}', style: time),
          ]),
        ]);
      },
    );
  }
}

/// Кнопка в плеере: войти в кинотеатр
class CinemaButton extends StatelessWidget {
  const CinemaButton({super.key});

  @override
  Widget build(BuildContext context) {
    final nav = NavScope.of(context);
    return IconButton(
      tooltip: 'Кинотеатр: обложка и текст во весь экран',
      onPressed: () => nav.go(const Nav('cinema')),
      icon: const Icon(Icons.fullscreen_rounded, size: 26, color: C.text),
    );
  }
}
