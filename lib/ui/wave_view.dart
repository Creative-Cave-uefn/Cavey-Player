import 'dart:math';

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/models.dart';
import '../core/wave.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

/// Страница «Моя волна»: большая кнопка, характер волны, что дальше и что волна выучила
class WavePage extends StatelessWidget {
  final bool compact;
  const WavePage({super.key, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final wave = app.wave;
    final p = app.player;
    final pad = compact ? 20.0 : 36.0;
    return ListenableBuilder(
      listenable: Listenable.merge([wave, p, app.lib]),
      builder: (context, _) {
        if (app.lib.allTracks.isEmpty) {
          return const EmptyState(
            icon: Icons.waves_rounded,
            title: 'Волне пока не из чего выбирать',
            text: 'Добавьте папки с музыкой — и волна начнёт подбирать треки под ваш вкус.',
          );
        }
        final active = wave.active;
        final upcoming = active ? p.queue.skip(p.index + 1).take(8).toList() : const <String>[];
        final top = wave.topArtists();
        final disliked = [for (final id in wave.taste.disliked) if (app.lib.data.tracks[id] != null) app.lib.data.tracks[id]!];
        return ListView(padding: EdgeInsets.fromLTRB(pad, 34, pad, 40), children: [
          _Hero(active: active, playing: active && p.playing),
          const SizedBox(height: 22),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final m in WaveMode.values)
              Tooltip(
                message: m.hint,
                waitDuration: const Duration(milliseconds: 400),
                child: ChoiceChip(
                  label: Text(m.title),
                  selected: wave.mode == m,
                  onSelected: (_) {
                    if (active) {
                      wave.setMode(m);
                    } else {
                      wave.start(m);
                    }
                  },
                  selectedColor: C.accent,
                  labelStyle: TextStyle(color: wave.mode == m ? C.accentInk : C.text, fontWeight: FontWeight.w600),
                  backgroundColor: C.raised,
                  side: BorderSide.none,
                  showCheckmark: false,
                ),
              ),
          ]),
          const SizedBox(height: 8),
          Text(wave.mode.hint, style: const TextStyle(color: C.muted, fontSize: 13)),
          const SizedBox(height: 22),
          const _Tune(),
          const SizedBox(height: 22),
          _Discover(compact: compact),
          if (upcoming.isNotEmpty) ...[
            const SizedBox(height: 30),
            Text('Дальше в волне', style: display(18)),
            const SizedBox(height: 10),
            for (var i = 0; i < upcoming.length; i++)
              if (app.lib.data.tracks[upcoming[i]] case final t?)
                _UpRow(
                  track: t,
                  onTap: () => p.jumpTo(p.index + 1 + i),
                  trailing: wave.trials.containsKey(t.id) ? const _NewBadge() : null,
                ),
          ],
          if (top.isNotEmpty) ...[
            const SizedBox(height: 30),
            Text('Волна по исполнителю', style: display(18)),
            const SizedBox(height: 4),
            const Text('Те, кого вы слушаете чаще всего. Нажмите — волна начнётся с них и похожих.',
                style: TextStyle(color: C.muted, fontSize: 13)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (key, _) in top)
                ActionChip(
                  avatar: const Icon(Icons.waves_rounded, size: 16, color: C.accent),
                  label: Text(app.lib.artist(key)?.name ?? key),
                  backgroundColor: C.raised,
                  side: BorderSide.none,
                  onPressed: () => wave.startFromArtist(app.lib.artist(key)?.name ?? key),
                ),
            ]),
          ],
          const SizedBox(height: 30),
          Text('Как волна учится', style: display(18)),
          const SizedBox(height: 8),
          const Text(
            'Дослушали трек — волна поставит больше похожего. Переключили в первые 30 секунд — '
            'этого исполнителя станет меньше, и он сразу пропадёт из ближайшей очереди. '
            '«Не нравится» в плеере убирает трек из волны насовсем. Ещё волна смотрит на ваши лайки, '
            'любимых исполнителей и что слушают друзья. Похожих исполнителей она находит по «радио» Deezer: '
            'кто звучит рядом с вашими любимыми — тот и близок по вкусу.',
            style: TextStyle(color: C.muted, height: 1.5),
          ),
          if (disliked.isNotEmpty) ...[
            const SizedBox(height: 18),
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Не нравится: ${disliked.length}', style: const TextStyle(fontWeight: FontWeight.w600)),
                children: [
                  for (final t in disliked)
                    _UpRow(
                      track: t,
                      trailing: TextButton(onPressed: () => wave.undislike(t.id), child: const Text('Вернуть')),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text('Забыть, чему волна научилась'),
              style: TextButton.styleFrom(foregroundColor: C.muted),
              onPressed: () async {
                final ok = await confirm(context,
                    title: 'Начать волну с нуля?',
                    text: 'Пропуски, «не нравится» и выученные предпочтения сотрутся. Лайки и прослушивания останутся.',
                    action: 'Сбросить');
                if (ok) wave.resetTaste();
              },
            ),
          ),
        ]);
      },
    );
  }
}

class _Hero extends StatefulWidget {
  final bool active;
  final bool playing;
  const _Hero({required this.active, required this.playing});

  @override
  State<_Hero> createState() => _HeroState();
}

class _HeroState extends State<_Hero> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(seconds: 6));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _Hero old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    // Волны двигаются, только пока играет: без этого страница зря грузит процессор
    if (widget.playing && !_anim.isAnimating) {
      _anim.repeat();
    } else if (!widget.playing && _anim.isAnimating) {
      _anim.stop();
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final p = app.player;
    final t = widget.active ? p.current : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: 230,
        color: C.raised,
        child: Stack(children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _anim,
                builder: (context, _) => CustomPaint(painter: _WavesPainter(_anim.value, widget.active)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(30, 28, 30, 28),
            child: Row(children: [
              PlayCircle(
                size: 76,
                playing: widget.playing,
                tooltip: widget.active ? (widget.playing ? 'Пауза' : 'Продолжить') : 'Включить волну',
                onPressed: () => widget.active ? p.toggle() : app.wave.start(),
              ),
              const SizedBox(width: 26),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Моя волна', style: display(40, weight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  Text(
                    t != null
                        ? 'Сейчас: ${t.title} — ${t.displayArtist}'
                        : app.wave.custom.isNotEmpty
                            ? 'Своя волна: ${app.wave.custom.join(', ')}'
                            : 'Бесконечный поток из вашей библиотеки под ваш вкус',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: C.muted, fontSize: 15),
                  ),
                  if (widget.active) ...[
                    const SizedBox(height: 14),
                    Wrap(spacing: 10, runSpacing: 8, children: [
                      if (t != null)
                        OutlinedButton.icon(
                          icon: Icon(app.wave.isUpvoted(t.id) ? Icons.thumb_up_alt_rounded : Icons.thumb_up_alt_outlined,
                              size: 16, color: app.wave.isUpvoted(t.id) ? C.accent : null),
                          label: const Text('Нравится'),
                          onPressed: app.wave.upvote,
                        ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.thumb_down_alt_outlined, size: 16),
                        label: const Text('Не нравится'),
                        onPressed: app.wave.dislike,
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.skip_next_rounded, size: 18),
                        label: const Text('Дальше'),
                        onPressed: p.next,
                      ),
                    ]),
                  ],
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _WavesPainter extends CustomPainter {
  final double t;
  final bool bright;
  _WavesPainter(this.t, this.bright);

  @override
  void paint(Canvas canvas, Size size) {
    for (var k = 0; k < 3; k++) {
      final path = Path();
      final amp = size.height * (0.07 + 0.04 * k);
      final base = size.height * (0.55 + 0.12 * k);
      final phase = t * 2 * pi * (k.isEven ? 1 : -1) + k * 1.7;
      path.moveTo(0, size.height);
      for (var x = 0.0; x <= size.width; x += 6) {
        final y = base + sin(x / size.width * 2 * pi * (1.2 + 0.4 * k) + phase) * amp;
        path.lineTo(x, y);
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      final alpha = (bright ? 0.16 : 0.08) - 0.03 * k;
      canvas.drawPath(path, Paint()..color = C.accent.withValues(alpha: alpha));
    }
  }

  @override
  bool shouldRepaint(_WavesPainter old) => old.t != t || old.bright != bright;
}

class _UpRow extends StatelessWidget {
  final Track track;
  final VoidCallback? onTap;
  final Widget? trailing;
  const _UpRow({required this.track, this.onTap, this.trailing});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(children: [
          CoverImage(track: track, size: 44, radius: 5),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(track.displayArtist,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
            ]),
          ),
          if (trailing != null) trailing!,
        ]),
      ),
    );
  }
}

/// Значок волны для боковой панели: виден, пока волна играет
Widget waveSidebarMark(BuildContext context) {
  final app = Services.of(context);
  return ListenableBuilder(
    listenable: app.wave,
    builder: (context, _) =>
        app.wave.active ? const Icon(Icons.graphic_eq_rounded, size: 16, color: C.accent) : const SizedBox.shrink(),
  );
}

/// Для меню трека и страницы исполнителя
void startWaveFrom(BuildContext context, Track t) {
  Services.of(context).wave.startFrom(t);
  NavScope.of(context).go(const Nav('wave'));
}

class _NewBadge extends StatelessWidget {
  const _NewBadge();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: C.accent.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(20)),
        child: const Text('новое', style: TextStyle(color: C.accent, fontSize: 12, fontWeight: FontWeight.w600)),
      );
}

/// «Новое из интернета»: волна сама качает треки на пробу
class _Discover extends StatelessWidget {
  final bool compact;
  const _Discover({required this.compact});

  static String _left(Duration d) {
    if (d.inHours >= 1) return 'ещё ${d.inHours} ч';
    if (d.inMinutes >= 1) return 'ещё ${d.inMinutes} мин';
    return 'скоро удалится';
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final wave = app.wave;
    final p = app.player;
    final list = wave.trialTracks..sort((a, b) => b.added.compareTo(a.added));
    final modeNote = switch (wave.mode) {
      WaveMode.favorite || WaveMode.popular => ' В режиме «${wave.mode.title}» новое не качается.',
      _ => '',
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.travel_explore_rounded, size: 20, color: C.accent),
          const SizedBox(width: 10),
          Expanded(child: Text('Новое из интернета', style: display(16))),
          Switch(value: wave.discover, onChanged: wave.setDiscover),
        ]),
        const SizedBox(height: 6),
        Text(
          'Волна сама скачивает треки, которые звучат рядом с вашими любимыми исполнителями, в папку «Моя волна». '
          'Если за сутки трек никто не послушает второй раз, не лайкнет и не добавит в плейлист — он удалится с Диска '
          'и больше не скачается. Не больше ${WaveService.dailyLimit} в день, сегодня: ${wave.downloadedToday}.$modeNote',
          style: const TextStyle(color: C.muted, fontSize: 13, height: 1.45),
        ),
        if (wave.discoverStatus.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(children: [
            const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.6)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(wave.discoverStatus,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
            ),
          ]),
        ],
        if (list.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final t in list)
            Builder(builder: (context) {
              final (kept, left) = wave.trialState(t.id);
              return _UpRow(
                track: t,
                onTap: () => p.playTracks(list, list.indexOf(t)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(kept ? 'останется' : _left(left), style: TextStyle(color: kept ? C.accent : C.faint, fontSize: 12)),
                  const SizedBox(width: 6),
                  if (!kept)
                    TextButton(onPressed: () => wave.keep(t.id), child: const Text('Оставить')),
                ]),
              );
            }),
        ],
      ]),
    );
  }
}

/// Настроение и свои исполнители
class _Tune extends StatelessWidget {
  const _Tune();

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final wave = app.wave;
    Widget chip(String label, bool on, VoidCallback onTap) => ChoiceChip(
          label: Text(label),
          selected: on,
          onSelected: (_) => onTap(),
          selectedColor: C.accent,
          labelStyle: TextStyle(color: on ? C.accentInk : C.text, fontWeight: FontWeight.w600),
          backgroundColor: C.raised,
          side: BorderSide.none,
          showCheckmark: false,
        );
    // Своя подписка на волну: этот блок создаётся как const и сам по себе при выборе не перерисовывался
    return ListenableBuilder(listenable: wave, builder: (context, _) => _build(context, wave, chip));
  }

  Widget _build(BuildContext context, WaveService wave, Widget Function(String, bool, VoidCallback) chip) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Настроение', style: display(16)),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        chip('Любое', wave.mood == null, () => wave.setMood(null)),
        for (final m in waveMoods) chip(m.title, wave.mood == m.id, () => wave.setMood(m.id)),
      ]),
      if (wave.mood != null && wave.tagsTotal > 0 && wave.tagsKnown < wave.tagsTotal) ...[
        const SizedBox(height: 8),
        Text('Узнаю настроение исполнителей в Last.fm: ${wave.tagsKnown} из ${wave.tagsTotal}',
            style: const TextStyle(color: C.faint, fontSize: 12)),
      ],
      const SizedBox(height: 22),
      Row(children: [
        Expanded(child: Text('Свои исполнители', style: display(16))),
        if (wave.custom.isNotEmpty)
          TextButton(onPressed: wave.clearCustom, child: const Text('Очистить')),
      ]),
      const SizedBox(height: 4),
      const Text('Волна будет держаться этих исполнителей и похожих на них — можно добавить и тех, кого нет в библиотеке.',
          style: TextStyle(color: C.muted, fontSize: 13)),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final c in wave.custom)
          InputChip(
            label: Text(c),
            backgroundColor: C.raised,
            side: BorderSide.none,
            onDeleted: () => wave.removeCustom(c),
          ),
        ActionChip(
          avatar: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Добавить'),
          backgroundColor: C.surface,
          side: const BorderSide(color: C.line),
          onPressed: () async {
            final name = await _pickArtist(context);
            if (name != null) wave.addCustom(name);
          },
        ),
      ]),
      if (wave.active && wave.similarInLibrary > 0) ...[
        const SizedBox(height: 14),
        Text('Похожих на текущий трек в библиотеке: ${wave.similarInLibrary}',
            style: const TextStyle(color: C.faint, fontSize: 12)),
      ],
    ]);
  }
}

/// Выбор исполнителя: из библиотеки с подсказками или любое имя
Future<String?> _pickArtist(BuildContext context) {
  final app = Services.of(context);
  final all = app.lib.artists;
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      final ctrl = TextEditingController();
      return StatefulBuilder(builder: (ctx, setState) {
        final q = ctrl.text.trim().toLowerCase();
        final hits = q.isEmpty
            ? (List.of(all)..sort((a, b) => b.tracks.length.compareTo(a.tracks.length))).take(8).toList()
            : all.where((a) => a.key.contains(q)).take(8).toList();
        return AlertDialog(
          title: Text('Добавить исполнителя', style: display(18)),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Имя исполнителя'),
                onChanged: (_) => setState(() {}),
                onSubmitted: (v) => Navigator.pop(ctx, v.trim().isEmpty ? null : v.trim()),
              ),
              const SizedBox(height: 10),
              for (final a in hits)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(a.name),
                  subtitle: Text('${a.tracks.length} в библиотеке', style: const TextStyle(color: C.faint, fontSize: 12)),
                  onTap: () => Navigator.pop(ctx, a.name),
                ),
              if (q.isNotEmpty && !hits.any((a) => a.key == q))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.travel_explore_rounded, size: 18),
                  title: Text('«${ctrl.text.trim()}» — найти в интернете'),
                  onTap: () => Navigator.pop(ctx, ctrl.text.trim()),
                ),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена'))],
        );
      });
    },
  );
}
