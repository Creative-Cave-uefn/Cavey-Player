import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:window_manager/window_manager.dart';

import 'log.dart';

// Всплывающее уведомление Windows — для случая, когда окно Cave Player свёрнуто или спрятано в трей.
// Показывается через системный PowerShell от его имени: так работает без регистрации приложения в системе.

String _xml(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');

/// Имя Cavey в системе для уведомлений: по нему Windows подписывает окошко («Cavey», а не «Windows PowerShell»)
const toastAppId = 'Cavey.Player';

/// Скрипт PowerShell, который показывает уведомление с заголовком [title] и строкой [body].
/// [iconPath] — картинка слева (круглая), как у Telegram и других программ. Звук системный отключён: играет свой
String toastScript(String title, String body, {String? iconPath}) {
  final icon = iconPath == null ? '' : _xml(iconPath.replaceAll('\\', '/'));
  final image = iconPath == null ? '' : '<image placement="appLogoOverride" hint-crop="circle" src="file:///$icon"/>';
  final psIcon = (iconPath ?? '').replaceAll("'", "''");
  return '''
\$ErrorActionPreference = 'Stop'
\$id = '$toastAppId'
try {
  \$k = 'HKCU:\\Software\\Classes\\AppUserModelId\\' + \$id
  if (-not (Test-Path \$k)) { New-Item \$k -Force | Out-Null }
  Set-ItemProperty \$k -Name DisplayName -Value 'Cavey'
  if ('$psIcon' -ne '') { Set-ItemProperty \$k -Name IconUri -Value '$psIcon' }
} catch { \$id = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe' }
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
\$x = New-Object Windows.Data.Xml.Dom.XmlDocument
\$x.LoadXml('<toast><visual><binding template="ToastGeneric">$image<text>${_xml(title).replaceAll("'", "''")}</text><text>${_xml(body).replaceAll("'", "''")}</text></binding></visual><audio silent="true"/></toast>')
\$n = New-Object Windows.UI.Notifications.ToastNotification \$x
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(\$id).Show(\$n)
''';
}

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

/// Окно спрятано в трей, свёрнуто или не в фокусе (на нём не смотрят)
Future<bool> windowIsHidden() async {
  try {
    if (!(await windowManager.isVisible()) || await windowManager.isMinimized()) return true;
    return !(await windowManager.isFocused());
  } catch (_) {
    return false;
  }
}

String? _toastIcon;

/// Круглый значок Cavey для уведомления: кладём картинку из сборки во временную папку один раз
Future<String?> _iconFile() async {
  final known = _toastIcon;
  if (known != null && File(known).existsSync()) return known;
  try {
    final bytes = (await rootBundle.load('assets/logo.png')).buffer.asUint8List();
    final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}cavey_toast_logo.png');
    await f.writeAsBytes(bytes, flush: true);
    return _toastIcon = f.path;
  } catch (e) {
    AppLog.warn('Значок для уведомления Windows не создался', e);
    return null;
  }
}

/// Показывает уведомление Windows. Ошибки не мешают: это лишь удобство.
Future<void> desktopToast(String body, {String title = 'Cavey'}) async {
  if (!Platform.isWindows) return;
  try {
    final icon = await _iconFile();
    await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-EncodedCommand',
      encodePowerShell(toastScript(title, body, iconPath: icon)),
    ]).timeout(const Duration(seconds: 15));
  } catch (e) {
    AppLog.warn('Уведомление Windows не показалось', e);
  }
}
