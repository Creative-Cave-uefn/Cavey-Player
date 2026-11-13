import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/library.dart';

/// On-device YouTube audio downloads for the Android app.
///
/// Unlike the Windows DownloadService this does not launch an EXE. The native
/// channel uses an Android-packaged yt-dlp runtime. Files remain in the app's
/// own Music/YouTube directory. Upload to Google Drive is an explicit choice.
class MobileYoutubeService extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel('cavey/youtube');

  final LibraryController library;

  bool busy = false;
  double progress = 0;
  String status = '';
  String? lastFile;
  String? error;

  MobileYoutubeService(this.library) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  /// Host-based allowlist: never send arbitrary URLs to an extractor.
  static bool isYoutubeUrl(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) return false;
    final host = uri.host.toLowerCase();
    if (host == 'youtu.be' || host == 'www.youtu.be') {
      return uri.pathSegments.isNotEmpty && uri.pathSegments.first.isNotEmpty;
    }
    if (!const {
      'youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com',
    }.contains(host)) {
      return false;
    }
    if (uri.path == '/watch') return (uri.queryParameters['v'] ?? '').isNotEmpty;
    return (uri.pathSegments.length >= 2 &&
        const {'shorts', 'live'}.contains(uri.pathSegments.first) &&
        uri.pathSegments[1].isNotEmpty);
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'progress') return;
    final args = call.arguments;
    if (args is! Map || !busy) return;
    final value = args['percent'];
    if (value is num) progress = (value.toDouble() / 100.0).clamp(0.0, 1.0);
    final message = args['message'];
    if (message is String && message.isNotEmpty) status = message;
    notifyListeners();
  }

  /// Download a single permitted audio stream, and optionally upload it to a
  /// selected, writable Google Drive music folder.
  Future<void> download(String url, {String? uploadFolderId}) async {
    final address = url.trim();
    if (busy) throw StateError('Загрузка уже выполняется');
    if (!isYoutubeUrl(address)) {
      throw FormatException('Нужна ссылка на одно видео YouTube (https://...)');
    }
    busy = true;
    progress = 0;
    error = null;
    lastFile = null;
    status = 'Подготавливаю загрузчик…';
    notifyListeners();
    try {
      final response = await _channel.invokeMapMethod<String, dynamic>(
        'download', {'url': address},
      );
      final path = response?['path'];
      if (path is! String || path.isEmpty) {
        throw StateError('Загрузчик не вернул путь к аудиофайлу');
      }
      final file = File(path);
      if (!await file.exists() || await file.length() == 0) {
        throw StateError('Получен пустой или недоступный аудиофайл');
      }
      lastFile = path;
      progress = 1;
      status = 'Аудио сохранено на телефоне';
      notifyListeners();

      if (uploadFolderId != null) {
        status = 'Добавляю в общую библиотеку Google Drive…';
        notifyListeners();
        await library.uploadOne(
          file,
          sourceId: uploadFolderId,
          folderId: uploadFolderId,
        );
        status = 'Сохранено на телефоне и в общей библиотеке';
      }
    } on PlatformException catch (e) {
      error = e.message ?? e.code;
      status = 'Загрузка не удалась';
    } catch (e) {
      error = e.toString();
      status = lastFile == null
          ? 'Загрузка не удалась'
          : 'Файл на телефоне сохранён, но загрузка в библиотеку не удалась';
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
