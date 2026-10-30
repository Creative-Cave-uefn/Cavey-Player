import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'log.dart';
import 'models.dart';
import 'player.dart';
import 'store.dart';

/// Значок в области уведомлений Windows. Крестик окна прячет Cave Player в трей, и музыка играет дальше;
/// закрыть совсем можно пунктом «Выйти» в меню значка.
class TrayController with TrayListener, WindowListener {
  final PlayerController player;
  final Settings settings;
  final Future<void> Function() save;
  final Future<void> Function() onQuit;

  /// Что делать по крестику в первый раз: true — в трей, false — закрыть совсем, null — не закрывать
  final Future<bool?> Function() askFirstTime;

  bool _ready = false;
  bool _closing = false;
  String _signature = '';

  TrayController({
    required this.player,
    required this.settings,
    required this.save,
    required this.onQuit,
    required this.askFirstTime,
  });

  Future<void> start() async {
    if (!Platform.isWindows) return;
    try {
      await trayManager.setIcon('assets/app_icon.ico');
      await trayManager.setToolTip('Cave Player');
      trayManager.addListener(this);
      // Закрытие окна обрабатываем сами: прячем в трей или аккуратно выходим, сохранив всё нужное
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);
      player.addListener(_refresh);
      _ready = true;
      await _refresh();
    } catch (e) {
      AppLog.warn('Трей не запустился, крестик закроет приложение как обычно', e);
      try {
        await windowManager.setPreventClose(false);
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    if (!_ready) return;
    _ready = false;
    player.removeListener(_refresh);
    try {
      await trayManager.destroy();
    } catch (_) {}
  }

  Future<void> showWindow() async {
    try {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      AppLog.warn('Не получилось показать окно', e);
    }
  }

  Future<void> _refresh() async {
    if (!_ready) return;
    final t = player.current;
    final playing = player.playing;
    final sig = '${t?.id}|$playing';
    if (sig == _signature) return;
    _signature = sig;
    try {
      await trayManager.setToolTip(t == null ? 'Cave Player' : _tip(t, playing));
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Открыть Cave Player'),
        MenuItem.separator(),
        if (t != null) MenuItem(key: 'now', label: _short('${t.title} — ${t.displayArtist}', 48), disabled: true),
        MenuItem(key: 'toggle', label: playing ? 'Пауза' : 'Играть', disabled: t == null),
        MenuItem(key: 'next', label: 'Следующий трек', disabled: t == null),
        MenuItem(key: 'prev', label: 'Предыдущий трек', disabled: t == null),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Выйти'),
      ]));
    } catch (e) {
      AppLog.warn('Меню трея не обновилось', e);
    }
  }

  static String _short(String s, int max) => s.length <= max ? s : '${s.substring(0, max - 1)}…';

  static String _tip(Track t, bool playing) => _short('${playing ? '▶' : '⏸'} ${t.title} — ${t.displayArtist}', 120);

  // ---------- значок ----------

  @override
  void onTrayIconMouseDown() => unawaited(showWindow());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(showWindow());
      case 'toggle':
        player.toggle();
      case 'next':
        player.next();
      case 'prev':
        player.previous();
      case 'quit':
        unawaited(onQuit());
    }
  }

  // ---------- крестик окна ----------

  @override
  void onWindowClose() => unawaited(_handleClose());

  Future<void> _handleClose() async {
    if (_closing) return;
    _closing = true;
    try {
      if (!settings.trayAsked) {
        final choice = await askFirstTime();
        if (choice == null) return;
        settings
          ..trayOnClose = choice
          ..trayAsked = true;
        await save();
      }
      if (settings.trayOnClose) {
        await windowManager.hide();
      } else {
        await onQuit();
      }
    } finally {
      _closing = false;
    }
  }
}
