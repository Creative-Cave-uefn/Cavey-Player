import 'package:flutter/foundation.dart';

/// Что сейчас сохраняется на Диск по просьбе человека (обложка, метаданные, аватарка…). По нему рисуется значок
/// справа внизу: человек видит, что правка ещё не дошла до друзей, и что именно сохраняется
class SaveTracker extends ChangeNotifier {
  int _next = 1;
  final Map<int, String> _active = {};

  /// Начинает отслеживать сохранение; вернуть номер нужно в [end]
  int begin(String label) {
    final id = _next++;
    _active[id] = label;
    notifyListeners();
    return id;
  }

  void end(int id) {
    if (_active.remove(id) != null) notifyListeners();
  }

  bool get busy => _active.isNotEmpty;

  /// Подписи по порядку начала
  List<String> get labels => _active.values.toList();
}
