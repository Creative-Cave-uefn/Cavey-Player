import 'package:flutter/material.dart';

import '../app.dart';
import 'lyrics_panel.dart';
import 'shell.dart';
import 'theme.dart';
import 'tracks_view.dart';
import 'widgets.dart';

/// Режим кинотеатра: половина экрана — крупная обложка, половина — текст песни.
/// Плеер и боковая панель прячутся и выезжают, когда к ним подводишь мышь
class CinemaPage extends StatelessWidget {
  final bool compact;
  const CinemaPage({super.key, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final p = app.player;
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final t = p.current;
        if (t == null) {
          return const EmptyState(
            icon: Icons.theaters_rounded,
            title: 'Ничего не играет',
            text: 'Включите трек — здесь будет его обложка и текст во весь экран.',
          );
        }
        return LayoutBuilder(builder: (context, box) {
          final narrow = box.maxWidth < 900;
          final half = narrow ? box.maxWidth : box.maxWidth / 2;
          final cover = (narrow ? box.maxHeight * 0.42 : half - 120).clamp(180.0, box.maxHeight - 220).toDouble();
          final art = Column(mainAxisSize: MainAxisSize.min, children: [
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                boxShadow: const [BoxShadow(color: Color(0x73000000), blurRadius: 60, offset: Offset(0, 24))],
              ),
              child: CoverImage(track: t, size: cover, radius: 22),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: cover,
              child: Text(t.title,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: display(narrow ? 24 : 30)),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: cover,
              child: Center(
                child: Links(parts: trackLinks(context, t, album: true), style: const TextStyle(color: C.muted, fontSize: 17)),
              ),
            ),
          ]);
          final lyrics = ShaderMask(
            // Текст плавно растворяется у верхнего и нижнего края
            shaderCallback: (r) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
              stops: [0.0, 0.12, 0.85, 1.0],
            ).createShader(r),
            blendMode: BlendMode.dstIn,
            child: Padding(
              padding: EdgeInsets.fromLTRB(narrow ? 24 : 12, 40, narrow ? 24 : 64, 0),
              child: LyricsBody(key: ValueKey(t.id), track: t, big: true),
            ),
          );
          if (narrow) {
            return Column(children: [
              Padding(padding: const EdgeInsets.only(top: 40), child: art),
              Expanded(child: lyrics),
            ]);
          }
          return Row(children: [
            SizedBox(width: half, child: Center(child: art)),
            Expanded(child: lyrics),
          ]);
        });
      },
    );
  }
}

/// Кнопка в плеере: войти в кинотеатр или выйти из него
class CinemaButton extends StatelessWidget {
  const CinemaButton({super.key});

  @override
  Widget build(BuildContext context) {
    final nav = NavScope.of(context);
    return ListenableBuilder(
      listenable: nav,
      builder: (context, _) {
        final on = nav.value.kind == 'cinema';
        return IconButton(
          tooltip: on ? 'Выйти из кинотеатра (Esc)' : 'Кинотеатр: обложка и текст во весь экран',
          onPressed: () => on ? (nav.canBack ? nav.back() : nav.go(const Nav('all'))) : nav.go(const Nav('cinema')),
          icon: Icon(on ? Icons.fullscreen_exit_rounded : Icons.theaters_rounded, color: on ? C.accent : C.text),
        );
      },
    );
  }
}
