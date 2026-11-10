import 'dart:math';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/models.dart';
import '../core/wave.dart';
import 'cinema_view.dart' show NowControls;
import 'shell.dart';
import 'theme.dart';
import 'tracks_view.dart' show showTrackMenu;
import 'web_views.dart';
import 'widgets.dart';
import 'ambient.dart';
import 'glass_popup.dart';

/// Страница «Моя волна» в духе стекла: без очереди — карусель обложек вокруг текущего трека,
/// «не нравится» и «нравится» под ней, все настройки — в панели «Настроить»
class WavePage extends StatelessWidget {
  final bool compact;
  const WavePage({super.key, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final wave = app.wave;
    final p = app.player;
    final pad = compact ? 20.0 : 40.0;
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
        final active = wave.active && p.current != null;
        // Ничего лишнего: название в одном углу, «Настроить» в другом, всё остальное — по центру экрана
        return LayoutBuilder(builder: (context, box) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight, minWidth: box.maxWidth),
              child: Stack(alignment: Alignment.center, children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(pad, active ? 56 : 92, pad, active ? 12 : 40),
                  child: active ? _NowFlow(compact: compact, height: box.maxHeight - 68) : _Idle(compact: compact),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 12,
                  child: IgnorePointer(child: Center(child: Text(wave.tuning ? 'Моя волна · режим настройки' : 'Моя волна', style: display(compact ? 24 : 30, color: C.muted)))),
                ),
                Positioned(
                  right: 18,
                  top: 12,
                  child: Row(children: [
                    _SettingsButton(), // не const: подсказка и точка обновляются
                    if (active) ...[
                      const SizedBox(width: 8),
                      // З5: выход из волны — музыка играет дальше; «Остановить» — музыка останавливается
                      TextButton.icon(
                        onPressed: () async {
                          await p.pause();
                          p.clearUpcoming();
                        },
                        style: TextButton.styleFrom(foregroundColor: C.muted),
                        icon: const Icon(Icons.stop_circle_outlined, size: 20),
                        label: const Text('Остановить волну'),
                      ),
                      IconButton(
                        tooltip: 'Закрыть (Esc)',
                        onPressed: () {
                          final nav = NavScope.of(context);
                          nav.canBack ? nav.back() : nav.go(const Nav('all'));
                        },
                        icon: const Icon(Icons.close_rounded, size: 26, color: C.text),
                      ),
                    ],
                  ]),
                ),
              ]),
            ),
          );
        });
      },
    );
  }
}

/// Единственная кнопка настроек в углу. Что сейчас выбрано — в подсказке;
/// точка — если выбрано настроение, свои исполнители или есть треки на пробе
class _SettingsButton extends StatelessWidget {
  const _SettingsButton();

  @override
  Widget build(BuildContext context) {
    final wave = Services.of(context).wave;
    final mood = moodById(wave.mood);
    final parts = [
      wave.mode.title,
      if (mood != null) mood.title,
      if (wave.custom.isNotEmpty) wave.custom.join(', '),
      if (wave.trials.isNotEmpty) '${wave.trials.length} на пробе',
    ];
    final marked = mood != null || wave.custom.isNotEmpty || wave.trials.isNotEmpty;
    return Tooltip(
      message: 'Настроить волну\n${parts.join(' · ')}',
      child: Material(
        color: C.raised,
        shape: const CircleBorder(side: BorderSide(color: C.line)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => showWaveSettings(context),
          child: SizedBox.square(
            dimension: 46,
            child: Stack(alignment: Alignment.center, children: [
              const Icon(Icons.tune_rounded, size: 20, color: C.text),
              if (marked)
                Positioned(
                  right: 10,
                  top: 10,
                  child: Container(width: 8, height: 8, decoration: BoxDecoration(color: C.accent, shape: BoxShape.circle)),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Карусель карточек вокруг играющего трека. Все карточки, и центральная тоже, — одинаковые «подложки» с обложкой,
/// названием и исполнителем; при смене трека каждая плавно переезжает на своё новое место (новый трек
/// выезжает в центр, а не появляется в нём сразу). Под центральной подложкой — подпись «почему этот трек»
/// и управление: перемотка, «не нравится» / «нравится», громкость. Сердечко — по центру обложки при наведении
class _NowFlow extends StatelessWidget {
  final bool compact;
  final double height;
  const _NowFlow({required this.compact, required this.height});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final p = app.player;
    final wave = app.wave;
    final t = p.current!;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      const gap = 22.0, pad = 24.0; // зазор между карточками и рамка соседней карточки
      const textShare = 0.27; // высота блока с названием в долях от обложки
      const controls = 214.0; // подпись и управление под центральной подложкой
      final byHeight = (height - controls - 24) / (1 + textShare);
      // Центральная карточка до 340 (в узком окне до 260), дальше только по месту
      final maxBig = compact ? 260.0 : 340.0;
      final big = math.max(150.0, math.min(maxBig, math.min(byHeight, w - 2 * pad)));
      final s1 = big * 0.74, s2 = big * 0.56;
      final dx1 = big / 2 + gap + (s1 + pad) / 2;
      final dx2 = dx1 + (s1 + pad) / 2 + gap + (s2 + pad) / 2;
      final showNear = w >= big + 2 * (gap + s1 + pad);
      final showFar = showNear && w >= 2 * (dx2 + (s2 + pad) / 2);
      final cx = w / 2;
      final slots = <int, ({double size, double dx, double angle, double opacity})>{
        -2: (size: s2, dx: -dx2, angle: -0.42, opacity: 0.55),
        -1: (size: s1, dx: -dx1, angle: -0.32, opacity: 0.85),
        0: (size: big, dx: 0, angle: 0, opacity: 1),
        1: (size: s1, dx: dx1, angle: 0.32, opacity: 0.85),
        2: (size: s2, dx: dx2, angle: 0.42, opacity: 0.55),
      };
      final bigH = big + 24 + big * textShare;
      final cards = <Widget>[];
      final seen = <String, int>{};
      // Центральная — последней, чтобы лежала поверх соседних
      for (final o in const [-2, 2, -1, 1, 0]) {
        final i = p.index + o;
        if (i < 0 || i >= p.queue.length) continue;
        final track = app.lib.data.tracks[p.queue[i]];
        if (track == null) continue;
        if (o != 0 && (!showNear || (!showFar && o.abs() == 2))) continue;
        final slot = slots[o]!;
        final n = seen[track.id] = (seen[track.id] ?? 0) + 1;
        final h = slot.size + 24 + slot.size * textShare;
        final duration = const Duration(milliseconds: 520);
        cards.add(AnimatedPositioned(
          // Ключ по треку: пока трек меняет место в карусели, это одна и та же карточка, и она едет, а не появляется заново
          key: ValueKey('${track.id}#$n'),
          duration: duration,
          curve: Curves.easeInOutCubic,
          left: cx + slot.dx - slot.size / 2 - 12,
          top: (big - slot.size) / 2,
          width: slot.size + 24,
          height: h,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: slot.opacity),
            duration: duration,
            curve: Curves.easeOutCubic,
            // Новая карточка не вспыхивает на месте, а проявляется (старт с нуля)
            builder: (context, op, child) => Opacity(opacity: op.clamp(0.0, 1.0), child: child),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: slot.angle),
              duration: duration,
              curve: Curves.easeInOutCubic,
              builder: (context, a, child) => Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0012)
                  ..rotateY(a),
                child: child,
              ),
              child: _FlowCard(track: track, current: o == 0, onTap: o == 0 ? null : () => p.jumpTo(i)),
            ),
          ),
        ));
      }
      final caption = wave.reasonFor(t.id);
      return Column(children: [
        SizedBox(height: bigH, child: Stack(clipBehavior: Clip.none, children: cards)),
        const SizedBox(height: 10),
        SizedBox(
          height: 20,
          child: Center(
            child: Text(caption,
                maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(color: C.faint, fontSize: 13)),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: big,
          child: NowControls(
            leftAction: _RoundGlass(
              tooltip: 'Не нравится — больше не попадётся',
              icon: Icons.thumb_down_alt_outlined,
              onPressed: wave.dislike,
            ),
            rightAction: _RoundGlass(
              tooltip: wave.isUpvoted(t.id) ? 'Нравится в волне — нажмите, чтобы отменить' : 'Нравится: больше похожего, без сохранения в любимое',
              icon: wave.isUpvoted(t.id) ? Icons.thumb_up_alt_rounded : Icons.thumb_up_alt_outlined,
              color: wave.isUpvoted(t.id) ? C.accent : C.text,
              onPressed: wave.upvote,
            ),
          ),
        ),
      ]);
    });
  }
}

class _FlowCard extends StatefulWidget {
  final Track track;
  final bool current;
  final VoidCallback? onTap;
  const _FlowCard({required this.track, required this.current, this.onTap});

  @override
  State<_FlowCard> createState() => _FlowCardState();
}

class _FlowCardState extends State<_FlowCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final current = widget.current;
    final app = Services.of(context);
    final card = Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x38000000),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: current ? const Color(0x66FFFFFF) : const Color(0x40FFFFFF)),
      ),
      child: LayoutBuilder(builder: (context, box) {
        final s = box.maxWidth;
        return Column(children: [
          // Обложка одного размера, а масштаб — через FittedBox: при анимации картинка не перечитывается
          SizedBox.square(
            dimension: s,
            child: Stack(children: [
              Positioned.fill(child: FittedBox(child: CoverImage(track: track, size: 360, radius: 20))),
              // Сердечко по центру обложки играющего трека, при наведении
              if (current)
                Positioned.fill(
                  child: Center(
                    child: ListenableBuilder(
                      listenable: app.lib,
                      builder: (context, _) {
                        final liked = app.lib.isLiked(track.id);
                        final show = _hover;
                        return IgnorePointer(
                          ignoring: !show,
                          child: AnimatedOpacity(
                            opacity: show ? 1 : 0,
                            duration: const Duration(milliseconds: 160),
                            child: Tooltip(
                              message: liked ? 'Убрать из любимого' : 'В любимое',
                              child: Material(
                                color: const Color(0x80000000),
                                shape: const CircleBorder(),
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: () => app.lib.toggleLike(track.id),
                                  child: SizedBox.square(
                                    dimension: math.max(48.0, s * 0.2),
                                    child: Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                                        size: math.max(26.0, s * 0.11), color: liked ? C.accent : Colors.white),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
            ]),
          ),
          const Spacer(),
          Text(track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: s * (current ? 0.07 : 0.075), fontWeight: FontWeight.w600)),
          Text(track.displayArtist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: s * 0.058, color: C.muted)),
          const Spacer(),
        ]);
      }),
    );
    // Правый клик — меню трека (вместо кнопки «…»)
    return MouseRegion(
      cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onSecondaryTapUp: (d) => showTrackMenu(context, track, null, d.globalPosition),
        child: card,
      ),
    );
  }
}

class _RoundGlass extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;
  const _RoundGlass({required this.tooltip, required this.icon, required this.onPressed, this.color = C.text});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: C.raised,
          shape: const CircleBorder(side: BorderSide(color: C.line)),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox.square(dimension: 54, child: Icon(icon, color: color, size: 22)),
          ),
        ),
      );
}

/// Волна не играет: большая кнопка, быстрый старт по настроению и по исполнителю
class _Idle extends StatefulWidget {
  final bool compact;
  const _Idle({required this.compact});

  @override
  State<_Idle> createState() => _IdleState();
}

class _IdleState extends State<_Idle> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(seconds: 8))..repeat();

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final wave = app.wave;
    final orb = widget.compact ? 220.0 : 280.0;
    final top = wave.topArtists(7);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Center(
        child: SizedBox.square(
          dimension: orb,
          child: Stack(alignment: Alignment.center, children: [
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: const BoxDecoration(color: C.surface, shape: BoxShape.circle, border: Border.fromBorderSide(BorderSide(color: C.line))),
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _anim,
                  builder: (context, _) => CustomPaint(size: Size.square(orb), painter: _WavesPainter(_anim.value, true)),
                ),
              ),
            ),
            PlayCircle(size: 92, playing: false, tooltip: 'Включить волну', onPressed: () => wave.start()),
          ]),
        ),
      ),
      const SizedBox(height: 18),
      Center(child: Text(wave.mode.hint, textAlign: TextAlign.center, style: const TextStyle(color: C.muted))),
      const SizedBox(height: 36),
      Text('Под настроение', style: display(20)),
      const SizedBox(height: 12),
      Wrap(spacing: 12, runSpacing: 12, children: [
        for (final m in waveMoods)
          _MoodTile(
            mood: m,
            selected: wave.active && wave.mood == m.id,
            onTap: () {
              wave.setMood(m.id);
              wave.start();
            },
          ),
      ]),
      if (top.isNotEmpty) ...[
        const SizedBox(height: 32),
        Text('По исполнителю', style: display(20)),
        const SizedBox(height: 14),
        Wrap(spacing: 18, runSpacing: 16, children: [
          for (final (key, _) in top)
            if (app.lib.artist(key) case final a?)
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => wave.startFromArtist(a.name),
                  child: SizedBox(
                    width: 104,
                    child: Column(children: [
                      ArtistPhoto(name: a.name, size: 96, fallback: CoverImage(track: a.coverTrack, size: 96, radius: 48)),
                      const SizedBox(height: 8),
                      Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
                    ]),
                  ),
                ),
              ),
        ]),
      ],
    ]);
  }
}

const _moodColors = {
  'energy': Color(0xFFFF9A4A),
  'calm': Color(0xFF5FD3B4),
  'sad': Color(0xFF7FA2FF),
  'love': Color(0xFFFF7FB2),
  'dark': Color(0xFFA08CFF),
  'focus': Color(0xFF9BDB6A),
};

const _moodIcons = {
  'energy': Icons.bolt_rounded,
  'calm': Icons.spa_outlined,
  'sad': Icons.water_drop_outlined,
  'love': Icons.favorite_border_rounded,
  'dark': Icons.nightlight_outlined,
  'focus': Icons.center_focus_strong_outlined,
};

/// Плитка настроения: стекло с цветным свечением из угла и значком. Наведение — свечение ярче,
/// включённое настроение — цветная обводка
class _MoodTile extends StatefulWidget {
  final WaveMood mood;
  final bool selected;
  final VoidCallback onTap;
  const _MoodTile({required this.mood, required this.selected, required this.onTap});

  @override
  State<_MoodTile> createState() => _MoodTileState();
}

class _MoodTileState extends State<_MoodTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = _moodColors[widget.mood.id] ?? C.accent;
    final lit = _hover || widget.selected;
    final r = BorderRadius.circular(18);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 1.03 : 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 156,
            height: 92,
            decoration: BoxDecoration(
              borderRadius: r,
              border: Border.all(color: widget.selected ? color.withValues(alpha: 0.8) : C.line, width: widget.selected ? 1.5 : 1),
              // Свечение из угла поверх стекла (у BoxDecoration градиент заменяет цвет, поэтому стекло вмешано в сам градиент)
              gradient: RadialGradient(
                center: const Alignment(-1, -1),
                radius: 1.6,
                colors: [
                  for (final c in smoothFadeColors(color.withValues(alpha: lit ? 0.42 : 0.26))) Color.alphaBlend(c, C.surface),
                ],
                stops: smoothFadeStops(),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(_moodIcons[widget.mood.id] ?? Icons.music_note_rounded, size: 22, color: color),
              const Spacer(),
              Text(widget.mood.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: C.text)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Панель «Настроить волну»: характер, настроение, свои исполнители, новинки, обучение
Future<void> showWaveSettings(BuildContext context) => showGlassDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780, maxHeight: 820),
          child: const _WaveSettings(),
        ),
      ),
    );

class _WaveSettings extends StatelessWidget {
  const _WaveSettings();

  @override
  Widget build(BuildContext context) {
    final wave = Services.of(context).wave;
    return ListenableBuilder(
      listenable: wave,
      builder: (context, _) {
        final disliked = [
          for (final id in wave.taste.disliked)
            if (wave.lib.data.tracks[id] != null) wave.lib.data.tracks[id]!
        ];
        return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(28, 22, 28, 24), children: [
          Row(children: [
            Expanded(child: Text('Настроить волну', style: display(24))),
            IconButton(tooltip: 'Закрыть', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
          ]),
          const SizedBox(height: 18),
          const Text('По характеру', style: TextStyle(color: C.muted, fontSize: 13)),
          const SizedBox(height: 10),
          Row(children: [
            for (final m in WaveMode.values) ...[
              if (m != WaveMode.values.first) const SizedBox(width: 8),
              Expanded(
                child: Tooltip(
                  message: m.hint,
                  child: Material(
                    color: wave.mode == m ? C.accent : C.raised,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => wave.setMode(m),
                      child: SizedBox(
                        height: 56,
                        child: Center(
                          child: Text(m.title,
                              style: TextStyle(fontWeight: FontWeight.w600, color: wave.mode == m ? C.accentInk : C.text)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ]),
          const SizedBox(height: 24),
          const _Tune(),
          const SizedBox(height: 24),
          _Discover(compact: false), // не const: иначе не перерисуется при изменениях волны
          const SizedBox(height: 24),
          Text('Как волна учится', style: display(16)),
          const SizedBox(height: 10),
          const _Learn(icon: Icons.thumb_up_alt_outlined, text: 'Нравится или дослушали — больше похожего'),
          const _Learn(icon: Icons.skip_next_rounded, text: 'Пропуск в первые 30 секунд — меньше такого'),
          const _Learn(icon: Icons.thumb_down_alt_outlined, text: 'Не нравится — больше не попадётся'),
          const _Learn(icon: Icons.travel_explore_rounded, text: 'Похожие треки — из Last.fm, по тому, что люди слушают вместе'),
          if (disliked.isNotEmpty)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Не нравится: ${disliked.length}', style: const TextStyle(fontWeight: FontWeight.w600)),
                children: [
                  for (final t in disliked)
                    _UpRow(track: t, trailing: TextButton(onPressed: () => wave.undislike(t.id), child: const Text('Вернуть'))),
                ],
              ),
            ),
          const SizedBox(height: 14),
          Row(children: [
            TextButton(
              style: TextButton.styleFrom(foregroundColor: C.muted),
              onPressed: () async {
                final ok = await confirm(context,
                    title: 'Начать волну с нуля?',
                    text: 'Пропуски, «не нравится» и выученные предпочтения сотрутся. Лайки и прослушивания останутся.',
                    action: 'Сбросить');
                if (ok) wave.resetTaste();
              },
              child: const Text('Сбросить обучение'),
            ),
            const Spacer(),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Готово')),
          ]),
        ]);
      },
    );
  }
}

class _Learn extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Learn({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: C.raised, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 17, color: C.accent),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
        ]),
      );
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
        app.wave.active ? Icon(Icons.graphic_eq_rounded, size: 16, color: C.accent) : const SizedBox.shrink(),
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
        child: Text('новое', style: TextStyle(color: C.accent, fontSize: 12, fontWeight: FontWeight.w600)),
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
          Icon(Icons.travel_explore_rounded, size: 20, color: C.accent),
          const SizedBox(width: 10),
          Expanded(child: Text('Новое из интернета', style: display(16))),
          Switch(value: wave.discover, onChanged: wave.setDiscover),
        ]),
        const SizedBox(height: 6),
        Text(
          'Волна сама скачивает треки, которые звучат рядом с вашими любимыми исполнителями, в папку «Моя волна». '
          'Если за сутки трек никто не послушает до конца или второй раз, не лайкнет и не добавит в плейлист — он уйдёт '
          'в корзину Диска и больше не скачается. Сегодня скачано: ${wave.downloadedToday} из ${wave.dailyLimit}.$modeNote',
          style: const TextStyle(color: C.muted, fontSize: 13, height: 1.45),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          const Text('Не больше в день:', style: TextStyle(color: C.muted, fontSize: 13)),
          for (final n in WaveService.dailyLimits)
            ChoiceChip(
              label: Text('$n'),
              selected: wave.dailyLimit == n,
              onSelected: (_) => wave.setDailyLimit(n),
            ),
        ]),
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
        if (wave.lastfmStatus.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(wave.lastfmStatus, style: const TextStyle(color: C.faint, fontSize: 12)),
        ],
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
  return showGlassDialog<String>(
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
