import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/desktop_notify.dart';
import '../core/notices.dart';
import '../core/notify_prefs.dart';
import '../core/toast_window.dart';
import 'share_dialog.dart' show openSharedThing;
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

  /// Карточка уезжает вправо; после анимации её убирают из списка
  bool leaving = false;
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
    // В «Настройках» для каждого вида уведомлений отдельно выбирается, играть ли звук и показывать ли карточку.
    // В колокольчике на вкладке «Компания» уведомление остаётся в любом случае
    final sound = preview || st.soundFor(n.kind);
    final popup = preview || st.popupFor(n.kind);
    // Звук: слышно, даже если окно далеко или спрятано
    if (sound) unawaited(NotifySound.play(st, force: preview));
    if (!popup) return;
    // Окно спрятано в трей, свёрнуто или не в фокусе — своё окошко уведомления поверх остальных окон
    if (st.notifySystem && (preview || await windowIsHidden())) {
      unawaited(_systemToast(app, n));
      if (!preview) return;
    }
    if (!mounted) return;
    final card = _Card(n, app.social.noticeBody(n));
    card.timer = Timer(const Duration(seconds: 12), () => _close(card));
    setState(() {
      _cards.add(card);
      while (_cards.length > maxCards) {
        _cards.removeAt(0).timer?.cancel();
      }
    });
  }

  /// Окошко уведомления вне плеера: ник, аватарка человека и текст. Не вышло — обычное уведомление Windows
  Future<void> _systemToast(AppServices app, Notice n) async {
    final lib = app.lib;
    final nick = lib.firstNameOf(n.from);
    final body = app.social.noticeBody(n);
    String? avatar;
    final fileId = lib.profileAvatar(n.from);
    if (fileId != null) {
      try {
        final bytes = await app.covers.forFile(fileId, px: 128);
        if (bytes != null && bytes.isNotEmpty) {
          final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}cavey_toast_av_${n.from.hashCode.abs()}.png');
          await f.writeAsBytes(bytes, flush: true);
          avatar = f.path;
        }
      } catch (_) {
        // без аватарки: останется кружок с буквой
      }
    }
    final shown = nick.trim().isEmpty ? n.from : nick.trim();
    // Приглашение в джем и запрос на вход можно принять или отклонить прямо в окошке
    final answerable = n.isJam && app.jam.noticeState(n) == null;
    final result = await showToastWindow(ToastSpec(
      title: nick,
      text: body,
      letter: shown.characters.first.toUpperCase(),
      avatarPath: avatar,
      bg: C.panel,
      line: C.line,
      accent: C.accent,
      fg: C.text,
      muted: C.muted,
      letterBg: friendColor(n.from),
      letterInk: C.accentInk,
      buttons: answerable,
      seconds: answerable ? 20 : 8,
    ));
    switch (result) {
      case ToastResult.failed:
        await desktopToast(body, title: nick);
      case ToastResult.accepted:
        app.social.markNoticeRead(n);
        unawaited(app.jam.acceptNotice(n));
      case ToastResult.declined:
        app.social.markNoticeRead(n);
        app.jam.declineNotice(n);
      case ToastResult.opened:
        app.social.markNoticeRead(n); // нажали на окошко — прочитано
      case ToastResult.closed:
        // «closed» — и крестик, и само погасло: по нему не понять, видел ли человек уведомление
        break;
    }
  }

  /// Закрыли крестиком или нажали на карточку: уведомление прочитано
  void _dismiss(_Card c) {
    Services.of(context).social.markNoticeRead(c.notice);
    _close(c);
  }

  void _close(_Card c) {
    if (c.leaving) return;
    c.timer?.cancel();
    if (!mounted) return;
    // Сначала уезжает вправо, потом убирается из стопки
    setState(() => c.leaving = true);
    Timer(const Duration(milliseconds: 320), () {
      if (mounted) setState(() => _cards.remove(c));
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.lib, app.lib.saves]),
      builder: (context, _) {
        final err = app.lib.syncError;
        final labels = app.lib.saves.labels;
        final saving = err != null || app.lib.hasUnsavedChanges || labels.isNotEmpty;
        if (_cards.isEmpty && !saving) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final c in _cards.reversed)
              Padding(
                key: ObjectKey(c),
                padding: const EdgeInsets.only(bottom: 8),
                child: _SlideIn(leaving: c.leaving, child: _NoticeCard(card: c, onClose: () => _dismiss(c))),
              ),
            if (saving) _SaveCloud(error: err, labels: labels),
          ],
        );
      },
    );
  }
}

/// Карточка уведомления: круглая аватарка человека слева, жирный заголовок, текст цветом акцента и крестик — как у Telegram.
/// Одна и та же в правом нижнем углу плеера и в предпросмотре «Настроек»
class ToastCard extends StatelessWidget {
  /// Ник человека
  final String title;
  final String text;
  final String? note;

  /// Аватарка человека, с которым связано уведомление (круглая, 48 на 48)
  final Widget leading;

  /// Кнопки под текстом (например «Войти»)
  final List<Widget> actions;
  final VoidCallback? onClose;
  const ToastCard({super.key, required this.title, required this.text, required this.leading, this.note, this.actions = const [], this.onClose});

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
          SizedBox.square(dimension: 48, child: leading),
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
    // Нажатие на саму карточку тоже закрывает её и отмечает прочитанной; кнопки внутри перехватывают свои нажатия
    return GestureDetector(
      onTap: onClose,
      child: ToastCard(
      title: app.lib.firstNameOf(n.from),
      leading: Avatar(email: n.from, name: app.lib.firstNameOf(n.from), size: 48),
      text: card.text,
      note: n.note,
      onClose: onClose,
      actions: [
        // Приглашение в джем и запрос на вход: «Принять» и «Отклонить»
        if (n.isJam) ...[
          FilledButton(
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 14)),
            onPressed: () {
              app.jam.acceptNotice(n);
              onClose();
            },
            child: const Text('Принять'),
          ),
          TextButton(
            onPressed: () {
              app.jam.declineNotice(n);
              onClose();
            },
            child: const Text('Отклонить'),
          ),
        ],
        if (track != null)
          TextButton.icon(
            onPressed: () {
              app.player.playTracks([track], 0);
              onClose();
            },
            icon: Icon(Icons.play_arrow_rounded, size: 18, color: C.accent),
            label: const Text('Слушать'),
          ),
        if (n.thing != null && n.thingKey != null)
          TextButton.icon(
            onPressed: () {
              if (!openSharedThing(app.lib, n.thing!, n.thingKey!)) app.lib.messages.add('Этого нет в вашей библиотеке');
              onClose();
            },
            icon: Icon(Icons.open_in_new_rounded, size: 18, color: C.accent),
            label: const Text('Открыть'),
          ),
      ],
      ),
    );
  }
}

/// Карточка выезжает из-за правого края окна и уезжает обратно, когда [leaving]
class _SlideIn extends StatefulWidget {
  final bool leaving;
  final Widget child;
  const _SlideIn({required this.leaving, required this.child});

  @override
  State<_SlideIn> createState() => _SlideInState();
}

class _SlideInState extends State<_SlideIn> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    // Первый кадр — за краем, следующий — на месте: так выезд виден
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final on = _shown && !widget.leaving;
    return AnimatedSlide(
      offset: on ? Offset.zero : const Offset(1.15, 0),
      duration: Duration(milliseconds: widget.leaving ? 280 : 360),
      curve: widget.leaving ? Curves.easeInCubic : Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: on ? 1 : 0,
        duration: Duration(milliseconds: widget.leaving ? 240 : 260),
        child: widget.child,
      ),
    );
  }
}

/// Облако «идёт сохранение на Диск». Подпись выезжает при наведении.
class _SaveCloud extends StatefulWidget {
  final String? error;

  /// Что именно сохраняется (обложка, метаданные…): пишется в подписи при наведении
  final List<String> labels;
  const _SaveCloud({this.error, this.labels = const []});
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
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Text(
                    err != null
                        ? 'Нет связи с Диском'
                        : widget.labels.isEmpty
                            ? 'Идёт сохранение на диск'
                            : widget.labels.length == 1
                                ? 'Сохраняется: ${widget.labels.first}'
                                : 'Сохраняется: ${widget.labels.first} и ещё ${widget.labels.length - 1}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: color, decoration: TextDecoration.none)),
                ),
              ),
            Icon(err != null ? Icons.cloud_off_rounded : Icons.cloud_upload_outlined, size: 16, color: color),
          ]),
          ),
        ),
      ),
    );
  }
}
