import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/desktop_notify.dart';
import '../core/notices.dart';
import 'theme.dart';

/// Правый нижний угол над плеером: живые уведомления «Вам» башенкой (новое — выше) и под ними значок облака,
/// пока изменения сохраняются на Диск (подпись раскрывается при наведении).
class NoticeTower extends StatefulWidget {
  const NoticeTower({super.key});

  @override
  State<NoticeTower> createState() => _NoticeTowerState();
}

class _Card {
  final Notice notice;
  final String text;
  Timer? timer;
  _Card(this.notice, this.text);
}

class _NoticeTowerState extends State<NoticeTower> {
  static const maxCards = 5;
  final _cards = <_Card>[]; // старые первыми; рисуем так, что новая оказывается сверху
  StreamSubscription<Notice>? _sub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sub ??= Services.of(context).social.noticeStream.stream.listen(_onNotice);
  }

  @override
  void dispose() {
    _sub?.cancel();
    for (final c in _cards) {
      c.timer?.cancel();
    }
    super.dispose();
  }

  Future<void> _onNotice(Notice n) async {
    final app = Services.of(context);
    final text = app.social.noticeLine(n);
    // Окно спрятано в трей или свёрнуто — вместо башенки уведомление Windows
    if (await windowIsHidden()) {
      unawaited(desktopToast(text));
      return;
    }
    if (!mounted) return;
    final card = _Card(n, text);
    card.timer = Timer(const Duration(seconds: 12), () => _close(card));
    setState(() {
      _cards.add(card);
      while (_cards.length > maxCards) {
        _cards.removeAt(0).timer?.cancel();
      }
    });
  }

  void _close(_Card c) {
    c.timer?.cancel();
    if (mounted) setState(() => _cards.remove(c));
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final err = app.lib.syncError;
        final saving = err != null || app.lib.hasUnsavedChanges;
        if (_cards.isEmpty && !saving) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final c in _cards.reversed)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: _NoticeCard(card: c, onClose: () => _close(c))),
            if (saving) _SaveCloud(error: err),
          ],
        );
      },
    );
  }
}

class _NoticeCard extends StatelessWidget {
  final _Card card;
  final VoidCallback onClose;
  const _NoticeCard({required this.card, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final n = card.notice;
    final track = app.lib.data.tracks[app.lib.data.resolve(n.trackIds.first)];
    final icon = switch (n.kind) {
      NoticeKind.like => Icons.favorite_rounded,
      NoticeKind.addToPlaylist => Icons.playlist_add_rounded,
      NoticeKind.share => Icons.share_rounded,
    };
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: 340,
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        decoration: BoxDecoration(
          color: C.raised,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: C.line),
          boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 14, offset: Offset(0, 4))],
        ),
        child: Row(children: [
          Icon(icon, size: 18, color: C.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(card.text, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, height: 1.35)),
              if (n.note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('«${n.note}»', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12.5)),
                ),
            ]),
          ),
          if (track != null)
            IconButton(
              tooltip: 'Слушать',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.play_arrow_rounded, color: C.accent),
              onPressed: () {
                app.player.playTracks([track], 0);
                onClose();
              },
            ),
          IconButton(
            tooltip: 'Закрыть',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded, size: 16, color: C.faint),
            onPressed: onClose,
          ),
        ]),
      ),
    );
  }
}

/// Облако «идёт сохранение на Диск». Подпись выезжает при наведении.
class _SaveCloud extends StatefulWidget {
  final String? error;
  const _SaveCloud({this.error});
  @override
  State<_SaveCloud> createState() => _SaveCloudState();
}

class _SaveCloudState extends State<_SaveCloud> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final err = widget.error;
    final color = err != null ? C.danger : C.muted;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 160),
        alignment: Alignment.centerRight,
        child: Container(
          height: 30,
          padding: EdgeInsets.symmetric(horizontal: _hover ? 12 : 7),
          decoration: BoxDecoration(
            color: C.raised.withValues(alpha: _hover ? 1 : 0.85),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: C.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (_hover)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(err != null ? 'Нет связи с Диском' : 'Идёт сохранение на диск',
                    style: TextStyle(fontSize: 12.5, color: color, decoration: TextDecoration.none)),
              ),
            Icon(err != null ? Icons.cloud_off_rounded : Icons.cloud_upload_outlined, size: 16, color: color),
          ]),
        ),
      ),
    );
  }
}
