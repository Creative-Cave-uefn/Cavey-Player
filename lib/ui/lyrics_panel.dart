import 'package:flutter/material.dart';

import '../app.dart';
import '../core/lyrics.dart';
import '../core/models.dart';
import 'theme.dart';

/// Панель справа с текстом песни. Синхронный текст подсвечивается по ходу трека,
/// клик по строке перематывает к ней.
class LyricsPanel extends StatelessWidget {
  const LyricsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return Container(
      width: 340,
      decoration: const BoxDecoration(color: C.surface, border: Border(left: BorderSide(color: C.line))),
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
                  : _LyricsBody(key: ValueKey(t.id), track: t),
            ),
          ]);
        },
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  const _Note(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 8, 22, 0),
        child: Text(text, style: const TextStyle(color: C.faint, height: 1.5)),
      );
}

class _LyricsBody extends StatefulWidget {
  final Track track;
  const _LyricsBody({super.key, required this.track});
  @override
  State<_LyricsBody> createState() => _LyricsBodyState();
}

class _LyricsBodyState extends State<_LyricsBody> {
  Future<Lyrics?>? _future;
  final List<GlobalKey> _keys = [];
  int _shown = -2;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_future != null) return;
    final app = Services.of(context);
    // Длительность помогает найти правильную версию; ждём её пару секунд после старта трека
    _future = () async {
      var d = app.player.duration;
      for (var i = 0; i < 10 && d == Duration.zero; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        d = app.player.duration;
      }
      return app.lyrics.forTrack(widget.track, d);
    }();
  }

  void _follow(int idx) {
    if (idx == _shown || idx < 0 || idx >= _keys.length) return;
    _shown = idx;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[idx].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, alignment: 0.35, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return FutureBuilder<Lyrics?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(22, 12, 22, 0),
            child: Align(alignment: Alignment.topLeft, child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        if (snap.hasError) {
          return const _Note('База текстов LRCLIB сейчас не отвечает. Откройте панель позже, попробую снова.');
        }
        final ly = snap.data;
        if (ly == null) return const _Note('Текст этой песни не нашёлся в базе LRCLIB.');
        if (ly.instrumental) return const _Note('Это инструментальная композиция, слов нет.');
        if (!ly.synced) {
          return ListView(padding: const EdgeInsets.fromLTRB(22, 4, 22, 32), children: [
            for (final l in ly.lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(l.text, style: const TextStyle(color: C.muted, fontSize: 15, height: 1.5)),
              ),
          ]);
        }
        while (_keys.length < ly.lines.length) {
          _keys.add(GlobalKey());
        }
        return ValueListenableBuilder<Duration>(
          valueListenable: app.player.position,
          builder: (context, pos, _) {
            final idx = ly.indexAt(pos + const Duration(milliseconds: 250));
            _follow(idx);
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 200),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var i = 0; i < ly.lines.length; i++)
                  InkWell(
                    key: _keys[i],
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => app.player.seek(ly.lines[i].at!),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      child: AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 200),
                        style: TextStyle(
                          fontSize: 19,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                          color: i == idx ? C.text : (i < idx ? C.faint : C.muted),
                        ),
                        child: Text(ly.lines[i].text.isEmpty ? '♪' : ly.lines[i].text),
                      ),
                    ),
                  ),
              ]),
            );
          },
        );
      },
    );
  }
}
