import 'dart:async';

import 'package:flutter/material.dart';

import '../core/lyrics.dart';
import '../core/models.dart';
import '../mobile_main.dart';
import '../ui/theme.dart';

/// Тексты песен в полноэкранном плеере: синхронные подсвечиваются по ходу трека
/// (если у строки есть слова с таймингом — подсвечиваются слова, как в караоке),
/// нажатие на строку перематывает к ней. Несинхронные показываются просто текстом.
class LyricsView extends StatefulWidget {
  const LyricsView({super.key, required this.services, required this.track});
  final MobileServices services;
  final Track track;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  Lyrics? lyrics;
  bool loading = true;
  bool failed = false;
  final ValueNotifier<int> current = ValueNotifier(-1);
  final List<GlobalKey> keys = [];
  final ScrollController scroll = ScrollController();
  int gen = 0;
  Timer? loadTimer;

  @override
  void initState() {
    super.initState();
    widget.services.player.position.addListener(tick);
    load();
  }

  @override
  void didUpdateWidget(LyricsView old) {
    super.didUpdateWidget(old);
    if (old.track.id != widget.track.id) load();
  }

  @override
  void dispose() {
    widget.services.player.position.removeListener(tick);
    loadTimer?.cancel();
    current.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> load({bool refresh = false}) async {
    final g = ++gen;
    setState(() {
      loading = true;
      failed = false;
      lyrics = null;
      current.value = -1;
    });
    final p = widget.services.player;
    final t = widget.track;
    var d = p.duration;
    if (d == Duration.zero && (t.durationMs ?? 0) > 0) d = Duration(milliseconds: t.durationMs!);
    try {
      final ly = await widget.services.lyrics.forTrack(t, d, refresh: refresh);
      if (!mounted || g != gen) return;
      setState(() {
        lyrics = ly;
        loading = false;
        keys
          ..clear()
          ..addAll(List.generate(ly?.lines.length ?? 0, (_) => GlobalKey()));
      });
    } catch (_) {
      if (!mounted || g != gen) return;
      setState(() {
        loading = false;
        failed = true;
      });
    }
  }

  void tick() {
    final ly = lyrics;
    if (ly == null || !ly.synced || ly.lines.isEmpty) return;
    final i = ly.indexAt(widget.services.player.position.value);
    if (i == current.value) return;
    current.value = i;
    if (i < 0 || i >= keys.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = i < keys.length ? keys[i].currentContext : null;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(ctx, alignment: 0.35, duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ly = lyrics;
    if (loading) return const Center(child: CircularProgressIndicator());
    if (failed) {
      return _Note(
        text: 'Не удалось загрузить текст. Проверьте интернет.',
        action: 'Повторить',
        onAction: () => load(refresh: true),
      );
    }
    if (ly == null) {
      return _Note(text: 'Текст этой песни не найден', action: 'Поискать ещё раз', onAction: () => load(refresh: true));
    }
    if (ly.instrumental || ly.lines.isEmpty) return const _Note(text: 'Инструментальный трек');
    // Тик нужен сразу: строка могла стать текущей, пока текст грузился
    WidgetsBinding.instance.addPostFrameCallback((_) => tick());
    return SingleChildScrollView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(8, 40, 8, 120),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (ly.approx)
          const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: Text('Версия текста может немного отличаться от трека', style: TextStyle(color: C.faint, fontSize: 12)),
          ),
        for (var i = 0; i < ly.lines.length; i++)
          KeyedSubtree(
            key: keys[i],
            child: _Line(
              line: ly.lines[i],
              index: i,
              synced: ly.synced,
              current: current,
              position: widget.services.player.position,
              onTap: ly.synced && ly.lines[i].at != null ? () => widget.services.player.seek(ly.lines[i].at!) : null,
            ),
          ),
      ]),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, this.action, this.onAction});
  final String text;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(text, textAlign: TextAlign.center, style: const TextStyle(color: C.muted)),
          if (action != null) TextButton(onPressed: onAction, child: Text(action!, style: TextStyle(color: C.accent))),
        ]),
      );
}

class _Line extends StatelessWidget {
  const _Line({required this.line, required this.index, required this.synced, required this.current, required this.position, this.onTap});
  final LyricLine line;
  final int index;
  final bool synced;
  final ValueNotifier<int> current;
  final ValueNotifier<Duration> position;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (line.text.trim().isEmpty) return const SizedBox(height: 18);
    return ValueListenableBuilder<int>(
      valueListenable: current,
      builder: (_, now, __) {
        final active = synced && now == index;
        final past = synced && now > index;
        final base = TextStyle(
          fontSize: active ? 27 : 24,
          height: 1.25,
          fontWeight: FontWeight.w700,
          color: !synced ? C.text : (active ? C.text : (past ? C.faint : C.muted.withValues(alpha: 0.55))),
        );
        final words = line.words;
        Widget text;
        if (active && words != null && words.isNotEmpty) {
          text = ValueListenableBuilder<Duration>(
            valueListenable: position,
            builder: (_, pos, __) => Text.rich(_karaoke(line.text, words, pos, base)),
          );
        } else {
          text = Text(line.text, style: base);
        }
        return InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7), child: text),
        );
      },
    );
  }

  /// Слова, до которых музыка уже дошла, — акцентным цветом, остальные — приглушённые
  static TextSpan _karaoke(String text, List<KWord> words, Duration pos, TextStyle base) {
    final spans = <InlineSpan>[];
    var at = 0;
    for (final w in words) {
      final from = w.from.clamp(0, text.length);
      final to = w.to.clamp(from, text.length);
      if (from > at) spans.add(TextSpan(text: text.substring(at, from), style: base.copyWith(color: C.muted)));
      spans.add(TextSpan(text: text.substring(from, to), style: base.copyWith(color: pos >= w.start ? C.accent : C.muted)));
      at = to;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at), style: base.copyWith(color: C.muted)));
    return TextSpan(children: spans);
  }
}
