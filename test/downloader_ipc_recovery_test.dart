import 'dart:io';

import 'package:cave_player/core/dl/service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reset connection can be retried once', () {
    expect(DownloadService.retryableDisconnect(
        const SocketException('Connection reset by peer')), isTrue);
    expect(DownloadService.retryableDisconnect(
        StateError('Модуль отключился до завершения задания.')), isTrue);
    expect(DownloadService.retryableDisconnect(
        StateError('Требуется Cavey-Downloader с протоколом 3.')), isFalse);
    expect(DownloadService.retryableDisconnect(
        const FormatException('Unsupported URL')), isFalse);
  });
}
