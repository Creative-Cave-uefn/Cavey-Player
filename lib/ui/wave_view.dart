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
          if (upcoming.isNotEmpty) ...[
            const SizedBox(height: 30),
            Text('Дальше в волне', style: display(18)),
            const SizedBox(height: 10),
            for (var i = 0; i < upcoming.length; i++)
              if (app.lib.data.tracks[upcoming[i]] case final t?)
                _UpRow(track: t, onTap: () => p.jumpTo(p.index + 1 + i)),
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
            'любимых исполнителей, что слушают друзья, и похожих артистов из интернета.',
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
                    t != null ? 'Сейчас: ${t.title} — ${t.displayArtist}' : 'Бесконечный поток из вашей библиотеки под ваш вкус',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: C.muted, fontSize: 15),
                  ),
                  if (widget.active) ...[
                    const SizedBox(height: 14),
                    Row(children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.thumb_down_alt_outlined, size: 16),
                        label: const Text('Не нравится'),
                        onPressed: app.wave.dislike,
                      ),
                      const SizedBox(width: 10),
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
