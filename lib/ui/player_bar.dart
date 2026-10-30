import 'package:flutter/material.dart';

import '../app.dart';
import '../core/player.dart';
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
    return Container(
      height: 92,
      decoration: const BoxDecoration(color: C.surface, border: Border(top: BorderSide(color: C.line))),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: ListenableBuilder(
        listenable: Listenable.merge([p, app.lib]),
        builder: (context, _) {
          final t = p.current;
          final nowPlaying = Row(children: [
            CoverImage(track: t, size: 58, radius: 6),
            const SizedBox(width: 14),
            Expanded(
              child: t == null
                  ? const Text('Выберите трек', style: TextStyle(color: C.faint))
                  : Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      InkWell(
                        onTap: () => NavScope.of(context).go(Nav('album', t.albumKey)),
                        child: Text(t.displayArtist,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
                      ),
                    ]),
            ),
            if (t != null) LikeButton(track: t),
          ]);

          final controls = Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(
                tooltip: p.shuffle ? 'Выключить перемешивание' : 'Перемешать',
                onPressed: p.toggleShuffle,
                icon: Icon(Icons.shuffle_rounded, color: p.shuffle ? C.accent : C.muted),
              ),
              IconButton(
                tooltip: 'Предыдущий',
                onPressed: t == null ? null : p.previous,
                icon: const Icon(Icons.skip_previous_rounded, size: 26, color: C.text),
              ),
              const SizedBox(width: 6),
              p.buffering && t != null
                  ? const SizedBox.square(
                      dimension: 40,
                      child: Padding(padding: EdgeInsets.all(9), child: CircularProgressIndicator(strokeWidth: 2.5)),
                    )
                  : PlayCircle(playing: p.playing, size: 40, onPressed: t == null ? null : p.toggle),
              const SizedBox(width: 6),
              IconButton(
                tooltip: 'Следующий',
                onPressed: t == null ? null : p.next,
                icon: const Icon(Icons.skip_next_rounded, size: 26, color: C.text),
              ),
              IconButton(
                tooltip: switch (p.repeat) {
                  RepeatSetting.off => 'Повторять всё',
                  RepeatSetting.all => 'Повторять трек',
                  RepeatSetting.one => 'Не повторять',
                },
                onPressed: p.cycleRepeat,
                icon: Icon(
                  p.repeat == RepeatSetting.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                  color: p.repeat == RepeatSetting.off ? C.muted : C.accent,
                ),
              ),
            ]),
            _Progress(player: p),
          ]);

          final lyricsButton = ValueListenableBuilder<bool>(
            valueListenable: p.lyricsOpen,
            builder: (context, open, _) => IconButton(
              tooltip: open ? 'Скрыть текст песни' : 'Текст песни',
              onPressed: () => p.lyricsOpen.value = !open,
              icon: Icon(Icons.lyrics_outlined, color: open ? C.accent : C.muted),
            ),
          );

          final soundButton = IconButton(
            tooltip: p.sleepActive ? _sleepLabel(p) : 'Звук и таймер сна',
            onPressed: () => _showSound(context),
            icon: Icon(
              p.sleepActive ? Icons.bedtime_rounded : Icons.tune_rounded,
              color: p.sleepActive || p.rate != 1.0 || p.normalize ? C.accent : C.muted,
            ),
          );

          final right = Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            soundButton,
            lyricsButton,
            IconButton(
              tooltip: 'Очередь',
              onPressed: t == null ? null : () => _showQueue(context),
              icon: const Icon(Icons.queue_music_rounded),
            ),
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
          ]);

          if (compact) {
            return Row(children: [
              Expanded(flex: 4, child: nowPlaying),
              Expanded(flex: 5, child: controls),
              soundButton,
              lyricsButton,
            ]);
          }
          return Row(children: [
            Expanded(flex: 3, child: nowPlaying),
            Expanded(flex: 4, child: controls),
            Expanded(flex: 3, child: right),
          ]);
        },
      ),
    );
  }

  static String _sleepLabel(PlayerController p) {
    if (p.sleepAfterTrack) return 'Остановлюсь после этого трека';
    final at = p.sleepAt;
    if (at == null) return 'Таймер сна выключен';
    final left = at.difference(DateTime.now());
    final min = (left.inSeconds / 60).ceil();
    return 'Пауза через ${min < 1 ? 1 : min} мин';
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
              Widget choice(String label, bool selected, VoidCallback onTap) => ChoiceChip(
                    label: Text(label),
                    selected: selected,
                    onSelected: (_) => onTap(),
                  );
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
                  const SizedBox(height: 8),
                  const Text('Скорость', style: TextStyle(color: C.muted, fontSize: 13)),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final r in const [0.75, 1.0, 1.25, 1.5, 2.0])
                      choice(r == 1.0 ? 'Обычная' : '×${r.toString().replaceAll('.', ',')}', p.rate == r, () => p.setRate(r)),
                  ]),
                  const SizedBox(height: 20),
                  Row(children: [
                    Text('Таймер сна', style: display(18)),
                    const Spacer(),
                    if (p.sleepActive) Text(_sleepLabel(p), style: const TextStyle(color: C.accent, fontSize: 13)),
                  ]),
                  const SizedBox(height: 10),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    choice('Выкл', !p.sleepActive, () => p.setSleepTimer(null)),
                    for (final m in const [15, 30, 45, 60, 90])
                      choice('$m мин', false, () => p.setSleepTimer(Duration(minutes: m))),
                    choice('После этого трека', p.sleepAfterTrack, p.setSleepAfterTrack),
                  ]),
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

class _ProgressState extends State<_Progress> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    const timeStyle = TextStyle(color: C.faint, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]);
    return ValueListenableBuilder<Duration>(
      valueListenable: p.position,
      builder: (context, pos, _) {
        final total = p.duration.inMilliseconds.toDouble();
        final value = (_drag ?? pos.inMilliseconds.toDouble()).clamp(0.0, total <= 0 ? 1.0 : total).toDouble();
        return Row(children: [
          SizedBox(
            width: 44,
            child: Text(formatDuration(Duration(milliseconds: value.round())), textAlign: TextAlign.right, style: timeStyle),
          ),
          Expanded(
            child: SizedBox(
              height: 24,
              child: Slider(
                value: value,
                max: total <= 0 ? 1.0 : total,
                onChanged: total <= 0 ? null : (v) => setState(() => _drag = v),
                onChangeEnd: (v) async {
                  await p.seek(Duration(milliseconds: v.round()));
                  if (mounted) setState(() => _drag = null);
                },
              ),
            ),
          ),
          SizedBox(width: 44, child: Text(formatDuration(p.duration), style: timeStyle)),
        ]);
      },
    );
  }
}
