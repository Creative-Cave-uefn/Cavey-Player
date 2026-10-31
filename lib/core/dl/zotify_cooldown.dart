import 'dart:convert';
import 'dart:io';

class ZotifyRateLimit implements Exception {
  final DateTime until;
  final bool serverProvided;
  ZotifyRateLimit(this.until, this.serverProvided);
  @override
  String toString() {
    final local = until.toLocal();
    final time = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
    return 'Spotify ограничил запросы (429). Загрузка остановлена; повторять не раньше $time. '
        '${serverProvided ? 'Пауза указана сервером в Retry-After.' : 'Retry-After не получен: плеер поставил паузу на минуту, срок ограничения сервера неизвестен.'} '
        'Повторный вход не требуется.';
  }
}

class ZotifyCooldown {
  DateTime? until;
  bool serverProvided = false;

  Future<void> check({File? stateFile, DateTime? now}) async {
    try {
      final j = jsonDecode(await stateFile!.readAsString());
      final saved = DateTime.tryParse('${j['until']}');
      if (saved != null && (until == null || saved.isAfter(until!))) {
        until = saved;
        serverProvided = j['serverProvided'] == true;
      }
    } catch (_) {}
    if (until != null && (now ?? DateTime.now()).isBefore(until!)) throw ZotifyRateLimit(until!, serverProvided);
  }

  Future<ZotifyRateLimit> pause(String? retryAfter, {File? stateFile, DateTime? now}) async {
    final current = now ?? DateTime.now();
    DateTime? deadline;
    final seconds = num.tryParse(retryAfter ?? '');
    if (seconds != null && seconds.isFinite && seconds >= 0 && seconds < 1000000000) {
      deadline = current.add(Duration(seconds: seconds.ceil()));
    } else {
      try { deadline = HttpDate.parse(retryAfter!); } catch (_) {}
    }
    serverProvided = deadline != null;
    final proposed = deadline != null && deadline.isAfter(current) ? deadline : current.add(const Duration(minutes: 1));
    if (until == null || proposed.isAfter(until!)) until = proposed;
    try {
      await stateFile?.writeAsString(jsonEncode({'until': until!.toUtc().toIso8601String(), 'serverProvided': serverProvided}));
    } catch (_) {}
    return ZotifyRateLimit(until!, serverProvided);
  }
}
