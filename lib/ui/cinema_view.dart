import 'package:flutter/material.dart';

import '../app.dart';
import '../core/player.dart';
import 'ambient.dart';
import 'lyrics_panel.dart';
import 'shell.dart';
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
  bool _lyrics = true;

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
      listenable: Listenable.merge([p, app.lib]),
      builder: (context, _) {
        final t = p.current;
        return Stack(children: [
          if (t == null)
            const EmptyState(
              icon: Icons.theaters_rounded,
              title: 'Ничего не играет',
              text: 'Включите трек — здесь будет его обложка и текст во весь экран.',
            )
          else
            LayoutBuilder(builder: (context, box) {
              final narrow = box.maxWidth < 900 || !_lyrics;
              final sideW = narrow ? box.maxWidth : box.maxWidth * 0.46;
              final cover = (narrow && _lyrics ? box.maxHeight * 0.34 : sideW - 120)
                  .clamp(160.0, (box.maxHeight - 330).clamp(160.0, 560.0))
                  .toDouble();
              final left = _NowPanel(width: cover);
              if (!_lyrics) return Center(child: left);
              final lyrics = ShaderMask(
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
              if (narrow) {
                return Column(children: [
                  Padding(padding: const EdgeInsets.only(top: 56), child: left),
                  Expanded(child: lyrics),
                ]);
              }
              return Row(children: [
                SizedBox(width: sideW, child: Center(child: left)),
                Expanded(child: lyrics),
              ]);
            }),
          Positioned(
            left: 16,
            top: 10,
            child: IconButton(
              tooltip: 'Закрыть (Esc)',
              onPressed: _close,
              icon: const Icon(Icons.close_rounded, size: 26, color: C.text),
            ),
          ),
          Positioned(
            right: 20,
            bottom: 18,
            child: IconButton(
              tooltip: _lyrics ? 'Скрыть текст' : 'Показать текст',
              onPressed: () => setState(() => _lyrics = !_lyrics),
              icon: Icon(Icons.lyrics_outlined, color: _lyrics ? C.text : C.muted),
            ),
          ),
        ]);
      },
    );
  }
}

/// Обложка, название, перемотка, управление и громкость — колонкой, как в Apple Music
class _NowPanel extends StatelessWidget {
  final double width;
  const _NowPanel({required this.width});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final p = app.player;
    final t = p.current!;
    final liked = app.lib.isLiked(t.id);
    return SizedBox(
      width: width,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 50, offset: Offset(0, 22))],
          ),
          child: CoverImage(track: t, size: width, radius: 14),
        ),
        const SizedBox(height: 22),
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Links(parts: trackLinks(context, t, album: true), style: const TextStyle(color: C.muted, fontSize: 15, fontWeight: FontWeight.w600)),
            ]),
          ),
          _Round(
            tooltip: liked ? 'Убрать из любимого' : 'В любимое',
            icon: liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            color: liked ? C.accent : C.text,
            onTap: () => app.lib.toggleLike(t.id),
          ),
          const SizedBox(width: 10),
          SizedBox.square(dimension: 34, child: Center(child: TrackMenu(track: t))),
        ]),
        const SizedBox(height: 18),
        _Seek(player: p),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
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
          IconButton(
            tooltip: 'Повтор',
            onPressed: p.cycleRepeat,
            icon: Icon(p.repeat == RepeatSetting.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                size: 22, color: p.repeat == RepeatSetting.off ? C.muted : C.accent),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          const Icon(Icons.volume_down_rounded, size: 20, color: C.muted),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(trackHeight: 4, activeTrackColor: C.text, inactiveTrackColor: const Color(0x40FFFFFF)),
              child: Slider(value: p.volume, max: 100, onChanged: (v) => p.setVolume(v, save: true)),
            ),
          ),
          const Icon(Icons.volume_up_rounded, size: 20, color: C.muted),
        ]),
      ]),
    );
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
      valueListenable: p.position,
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
      icon: const Icon(Icons.theaters_rounded, color: C.text),
    );
  }
}
