import 'dart:io';

import 'package:cave_player/core/dl/service.dart';
import 'package:cave_player/core/library.dart';
import 'package:flutter_test/flutter_test.dart';

// The cancellation path does not touch the library until an actual upload.
class _UnusedLibrary implements LibraryController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a queued download cancels immediately and can be cleared', () {
    final service = DownloadService(_UnusedLibrary(), Directory.systemTemp);
    final job = DownloadJob('spotify playlist', 'folder', 'Music');
    service.jobs.add(job);
    service.cancel(job);
    expect(job.cancelRequested, isTrue);
    expect(job.state, JobState.cancelled);
    expect(job.log, contains(contains('Отмена запрошена')));
    service.cancel(job); // Idempotent; no second cancellation event.
    expect(job.log.length, 1);
    service.clearFinished();
    expect(service.jobs, isEmpty);
    service.dispose();
  });

  test('an active download changes to a stopping state', () {
    final service = DownloadService(_UnusedLibrary(), Directory.systemTemp);
    final job = DownloadJob('spotify playlist', 'folder', 'Music')
      ..state = JobState.running;
    service.jobs.add(job);
    service.cancel(job);
    expect(job.cancelRequested, isTrue);
    // The worker sets "cancelled" after the process has actually stopped.
    expect(job.state, JobState.running);
    service.dispose();
  });


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
