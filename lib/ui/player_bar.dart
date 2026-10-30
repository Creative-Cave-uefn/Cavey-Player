import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/player.dart';
import 'cinema_view.dart';
import 'shell.dart';
import 'theme.dart';
import 'tracks_view.dart';
import 'widgets.dart';

class PlayerBar extends StatelessWidget {
  final bool compact;
  const PlayerBar({super.key, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final p = app.player;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Container(
        height: 76,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(38), border: Border.all(color: C.line)),
        child: ListenableBuilder(
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

            // Карточка трека: тёмная вставка посреди капсулы, прогресс — тонкой полосой по низу
            final card = Container(
              height: 56,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(color: const Color(0x4D000000), borderRadius: BorderRadius.circular(16)),
              child: Stack(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(7, 0, 6, 3),
                  child: Row(children: [
                    t == null
                        ? CoverImage(track: t, size: 42, radius: 9)
                        : Tooltip(
                            message: 'Открыть альбом',
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: () => NavScope.of(context).go(Nav('album', t.albumKey)),
                                child: CoverImage(track: t, size: 42, radius: 9),
                              ),
                            ),
                          ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: t == null
                          ? const Text('Выберите трек', style: TextStyle(color: C.faint))
                          : Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(t.title,
                                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                              const SizedBox(height: 2),
                              Links(parts: trackLinks(context, t, album: true), style: const TextStyle(color: C.muted, fontSize: 13)),
                            ]),
                    ),
                    if (t != null && !compact) _Time(player: p),
                    if (t != null && app.wave.active) ...[
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
                    if (t != null) LikeButton(track: t),
                  ]),
                ),
                Positioned(left: 0, right: 0, bottom: 0, child: _Progress(player: p)),
              ]),
            );

            final lyricsButton = ValueListenableBuilder<bool>(
              valueListenable: p.lyricsOpen,
              builder: (context, open, _) => IconButton(
                tooltip: open ? 'Скрыть текст песни' : 'Текст песни',
                onPressed: () => p.lyricsOpen.value = !open,
                icon: Icon(Icons.lyrics_outlined, color: open ? C.accent : ink),
              ),
            );

            final soundButton = IconButton(
              tooltip: 'Звук',
              onPressed: () => _showSound(context),
              icon: Icon(Icons.tune_rounded, color: p.normalize ? C.accent : ink),
            );

            if (compact) {
              return Row(children: [
                controls,
                const SizedBox(width: 8),
                Expanded(child: card),
                lyricsButton,
              ]);
            }
            return Row(children: [
              controls,
              const SizedBox(width: 12),
              Expanded(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 620), child: card))),
              const SizedBox(width: 12),
              soundButton,
              lyricsButton,
              const CinemaButton(),
              IconButton(
                tooltip: 'Очередь',
                onPressed: t == null ? null : () => _showQueue(context),
                icon: const Icon(Icons.queue_music_rounded, color: ink),
              ),
              _VolumeControl(p),
            ]);
          },
        ),
      ),
    );
  }

  void _showSound(BuildContext context) {
    final app = Services.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        alignment: Alignment.bottomRight,
        insetPadding: const EdgeInsets.fromLTRB(24, 24, 24, 110),
        child: SizedBox(
          width: 380,
          child: ListenableBuilder(
            listenable: app.player,
            builder: (context, _) {
              final p = app.player;
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Звук', style: display(18)),
                  const SizedBox(height: 6),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: p.normalize,
                    onChanged: p.setNormalize,
                    title: const Text('Выравнивать громкость'),
                    subtitle: const Text('Тихие и громкие треки звучат одинаково', style: TextStyle(color: C.faint, fontSize: 13)),
                  ),
                ]),
              );
            },
          ),
        ),
      ),
    );
  }

  void _showQueue(BuildContext context) {
    final app = Services.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        alignment: Alignment.bottomRight,
        insetPadding: const EdgeInsets.fromLTRB(24, 24, 24, 110),
        child: SizedBox(
          width: 420,
          height: 520,
          child: ListenableBuilder(
            listenable: app.player,
            builder: (context, _) {
              final p = app.player;
              final cur = p.current;
              final count = p.queue.length - p.index - 1 < 0 ? 0 : p.queue.length - p.index - 1;
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 12, 12),
                  child: Row(children: [
                    Expanded(child: Text('Очередь', style: display(18))),
                    if (count > 0)
                      TextButton(onPressed: p.clearUpcoming, child: const Text('Очистить')),
                  ]),
                ),
                if (cur != null)
                  ListTile(
                    leading: CoverImage(track: cur, size: 40),
                    title: Text(cur.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.accent)),
                    subtitle: Text(cur.displayArtist, maxLines: 1, style: const TextStyle(color: C.muted)),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
                  child: Text(count == 0 ? 'Дальше ничего нет' : 'Дальше · перетаскивайте, чтобы поменять порядок',
                      style: const TextStyle(color: C.muted, fontSize: 13)),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    itemCount: count,
                    onReorder: (from, to) {
                      if (to > from) to--;
                      p.moveInQueue(p.index + 1 + from, p.index + 1 + to);
                    },
                    itemBuilder: (context, i) {
                      final qi = p.index + 1 + i;
                      final t = app.lib.data.tracks[p.queue[qi]];
                      return ReorderableDragStartListener(
                        key: ValueKey('q$qi:${p.queue[qi]}'),
                        index: i,
                        child: t == null
                            ? const SizedBox(height: 1)
                            : ListTile(
                                dense: true,
                                leading: CoverImage(track: t, size: 36),
                                title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Text(t.displayArtist, maxLines: 1, style: const TextStyle(color: C.muted)),
                                trailing: IconButton(
                                  tooltip: 'Убрать из очереди',
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(Icons.close_rounded, size: 18, color: C.faint),
                                  onPressed: () => p.removeAt(qi),
                                ),
                                onTap: () => p.jumpTo(qi),
                              ),
                      );
                    },
                  ),
                ),
              ]);
            },
          ),
        ),
      ),
    );
  }
}

class _Progress extends StatefulWidget {
  final PlayerController player;
  const _Progress({required this.player});
  @override
  State<_Progress> createState() => _ProgressState();
}

/// Тонкая полоса прогресса по низу карточки трека: клик и перетаскивание перематывают,
/// при наведении становится толще
class _ProgressState extends State<_Progress> {
  double? _drag;
  bool _hover = false;

  void _seekTo(double dx, double width, {bool commit = false}) {
    final total = widget.player.duration.inMilliseconds.toDouble();
    if (total <= 0 || width <= 0) return;
    final v = (dx / width).clamp(0.0, 1.0) * total;
    if (commit) {
      setState(() => _drag = null);
      widget.player.seek(Duration(milliseconds: v.round()));
    } else {
      setState(() => _drag = v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _seekTo(d.localPosition.dx, w, commit: true),
          onHorizontalDragUpdate: (d) => _seekTo(d.localPosition.dx, w),
          onHorizontalDragEnd: (_) {
            final v = _drag;
            if (v == null) return;
            setState(() => _drag = null);
            p.seek(Duration(milliseconds: v.round()));
          },
          child: SizedBox(
            height: 10,
            child: ValueListenableBuilder<Duration>(
              valueListenable: p.position,
              builder: (context, pos, _) {
                final total = p.duration.inMilliseconds.toDouble();
                final value = _drag ?? pos.inMilliseconds.toDouble();
                final f = total <= 0 ? 0.0 : (value / total).clamp(0.0, 1.0);
                final h = _hover || _drag != null ? 4.0 : 2.5;
                return Align(
                  alignment: Alignment.bottomLeft,
                  child: Stack(children: [
                    Container(height: h, width: w, color: const Color(0x26FFFFFF)),
                    Container(height: h, width: w * f, color: const Color(0xD9FFFFFF)),
                  ]),
                );
              },
            ),
          ),
        ),
      );
    });
  }
}

/// «1:24 / 3:41» в карточке трека
class _Time extends StatelessWidget {
  final PlayerController player;
  const _Time({required this.player});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Duration>(
        valueListenable: player.position,
        builder: (context, pos, _) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text('${formatDuration(pos)} / ${formatDuration(player.duration)}',
              style: const TextStyle(color: C.faint, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
        ),
      );
}


/// Динамик и ползунок громкости. Колесо мыши над ними меняет громкость: на 5 %, с Shift на 1 %.
class _VolumeControl extends StatefulWidget {
  final PlayerController p;
  const _VolumeControl(this.p);

  @override
  State<_VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<_VolumeControl> {
  double _acc = 0;
  Timer? _save;

  @override
  void dispose() {
    _save?.cancel();
    super.dispose();
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
      final v = (p.volume + whole).clamp(0, 100).toDouble();
      p.setVolume(v);
      _save?.cancel();
      _save = Timer(const Duration(milliseconds: 500), () => p.setVolume(v, save: true));
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    return Listener(
      onPointerSignal: _onScroll,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(p.volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded, size: 18),
        SizedBox(
          width: 120,
          child: Slider(
            value: p.volume.clamp(0.0, 100.0).toDouble(),
            max: 100,
            onChanged: (v) => p.setVolume(v),
            onChangeEnd: (v) => p.setVolume(v, save: true),
          ),
        ),
        SizedBox(
          width: 36,
          child: Text('${p.volume.round()}%', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: C.faint)),
        ),
      ]),
    );
  }
}
