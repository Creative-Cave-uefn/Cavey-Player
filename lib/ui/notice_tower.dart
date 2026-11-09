import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/desktop_notify.dart';
import '../core/notices.dart';
import '../core/notify_prefs.dart';
import 'widgets.dart';
import 'theme.dart';
import 'glass_popup.dart';

/// Правый нижний угол над плеером: живые уведомления «Вам» башенкой (новое — выше) и под ними значок облака,
/// пока изменения сохраняются на Диск (подпись раскрывается при наведении).
class NoticeTower extends StatefulWidget {
  const NoticeTower({super.key});

  @override
  State<NoticeTower> createState() => _NoticeTowerState();
}

/// Следующее уведомление — пример из «Настроек»: настоящая карточка, звук и (если включено) уведомление Windows,
/// даже когда уведомления выключены
bool noticePreviewing = false;

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
    final st = app.settings;
    final preview = noticePreviewing;
    noticePreviewing = false;
    if (!preview && !st.notifyOn) return;
    final text = app.social.noticeLine(n);
    // Мягкий звук: слышно, даже если окно далеко или спрятано
    unawaited(NotifySound.play(st, force: preview));
    // Окно спрятано в трей, свёрнуто или не в фокусе — уведомление Windows, чтобы заметить его вне плеера
    if (st.notifySystem && (preview || await windowIsHidden())) {
      unawaited(desktopToast(text));
      if (!preview) return;
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

/// Карточка уведомления: круглый значок слева, жирный заголовок, текст цветом акцента и крестик — как у Telegram.
/// Одна и та же в правом нижнем углу плеера и в предпросмотре «Настроек»
class ToastCard extends StatelessWidget {
  final String title;
  final String text;
  final String? note;

  /// Кнопки под текстом (например «Войти»)
  final List<Widget> actions;
  final VoidCallback? onClose;
  const ToastCard({super.key, required this.title, required this.text, this.note, this.actions = const [], this.onClose});

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: 360,
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        decoration: BoxDecoration(
          color: C.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: C.line),
          boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 6))],
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipOval(child: BrandMark(size: 48)),
          const SizedBox(width: 14),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: C.text)),
                const SizedBox(height: 3),
                Text(text, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, height: 1.35, color: C.accent)),
                if (note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('«$note»', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12.5)),
                  ),
                if (actions.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 4, runSpacing: 2, children: actions)),
              ]),
            ),
          ),
          if (onClose != null)
            IconButton(
              tooltip: 'Закрыть',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded, size: 18, color: C.faint),
              onPressed: onClose,
            ),
        ]),
      ),
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
    final track = n.trackIds.isEmpty ? null : app.lib.data.tracks[app.lib.data.resolve(n.trackIds.first)];
    return ToastCard(
      title: 'Cavey',
      text: card.text,
      note: n.note,
      onClose: onClose,
      actions: [
        if (n.kind == NoticeKind.jamInvite)
          TextButton(
            onPressed: () {
              app.jam.acceptNotice(n);
              onClose();
            },
            child: const Text('Войти'),
          ),
        if (n.kind == NoticeKind.jamRequest)
          TextButton(
            onPressed: () {
              app.jam.acceptNotice(n);
              onClose();
            },
            child: const Text('Принять'),
          ),
        if (track != null)
          TextButton.icon(
            onPressed: () {
              app.player.playTracks([track], 0);
              onClose();
            },
            icon: Icon(Icons.play_arrow_rounded, size: 18, color: C.accent),
            label: const Text('Слушать'),
          ),
      ],
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
        child: GlassPanel(
          radius: 15,
          shadow: const [],
          padding: EdgeInsets.symmetric(horizontal: _hover ? 12 : 7),
          child: SizedBox(
          height: 28,
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
      ),
    );
  }
}
