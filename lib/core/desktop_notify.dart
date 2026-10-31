import 'dart:convert';
import 'dart:io';

import 'package:window_manager/window_manager.dart';

import 'log.dart';

// Всплывающее уведомление Windows — для случая, когда окно Cave Player свёрнуто или спрятано в трей.
// Показывается через системный PowerShell от его имени: так работает без регистрации приложения в системе.

String _xml(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');

/// Скрипт PowerShell, который показывает уведомление с заголовком [title] и строкой [body]
String toastScript(String title, String body) => '''
\$ErrorActionPreference = 'Stop'
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
\$x = New-Object Windows.Data.Xml.Dom.XmlDocument
\$x.LoadXml('<toast><visual><binding template="ToastText02"><text id="1">${_xml(title).replaceAll("'", "''")}</text><text id="2">${_xml(body).replaceAll("'", "''")}</text></binding></visual></toast>')
\$n = New-Object Windows.UI.Notifications.ToastNotification \$x
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe').Show(\$n)
''';

/// Строка для параметра -EncodedCommand: UTF-16 с порядком байтов «младший первым», в base64
String encodePowerShell(String script) {
  final bytes = <int>[];
  for (final u in script.codeUnits) {
    bytes
      ..add(u & 0xFF)
      ..add(u >> 8);
  }
  return base64Encode(bytes);
}

/// Окно спрятано в трей или свёрнуто
Future<bool> windowIsHidden() async {
  try {
    return !(await windowManager.isVisible()) || await windowManager.isMinimized();
  } catch (_) {
    return false;
  }
}

/// Показывает уведомление Windows. Ошибки не мешают: это лишь удобство.
Future<void> desktopToast(String body, {String title = 'Cavey'}) async {
  if (!Platform.isWindows) return;
  try {
    await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-EncodedCommand',
      encodePowerShell(toastScript(title, body)),
    ]).timeout(const Duration(seconds: 15));
  } catch (e) {
    AppLog.warn('Уведомление Windows не показалось', e);
  }
}
