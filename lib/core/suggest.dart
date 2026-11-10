// Подсказки при вводе исполнителя и альбома в окнах правки: поиск по уже существующим
// без учёта регистра и диакритики, начинающиеся с запроса — выше.

import 'text_fold.dart';

class Suggestion {
  final String text;

  /// Вторая строка: исполнитель альбома или число треков
  final String sub;

  /// Любой объект для показа (например, трек для обложки)
  final Object? ref;

  /// Чем больше, тем выше при равных совпадениях (число треков)
  final int weight;
  const Suggestion(this.text, {this.sub = '', this.ref, this.weight = 0});
}

/// Подходящие под [query] подсказки. Пустой запрос — самые крупные. Порядок: начало названия, начало слова, вхождение
List<Suggestion> rankSuggestions(Iterable<Suggestion> all, String query, {int limit = 40}) {
  final q = foldText(query);
  final scored = <(int, Suggestion)>[];
  for (final s in all) {
    if (q.isEmpty) {
      scored.add((0, s));
      continue;
    }
    final f = foldText(s.text);
    int? score;
    if (f.startsWith(q)) {
      score = 0;
    } else if (f.contains(' $q')) {
      score = 1;
    } else if (f.contains(q)) {
      score = 2;
    }
    if (score != null) scored.add((score, s));
  }
  scored.sort((a, b) {
    if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
    if (a.$2.weight != b.$2.weight) return b.$2.weight.compareTo(a.$2.weight);
    return foldText(a.$2.text).compareTo(foldText(b.$2.text));
  });
  return [for (final e in scored.take(limit)) e.$2];
}

/// Есть ли среди подсказок в точности то, что набрано (тогда «Создать …» не нужно)
bool hasExactSuggestion(Iterable<Suggestion> all, String query) {
  final q = foldText(query);
  return q.isNotEmpty && all.any((s) => foldText(s.text) == q);
}

/// Для поля, где через запятую перечислены несколько исполнителей: последняя часть — то, что сейчас набирают
({String head, String tail}) splitLastArtist(String text) {
  final i = text.lastIndexOf(',');
  if (i < 0) return (head: '', tail: text.trimLeft());
  return (head: text.substring(0, i + 1), tail: text.substring(i + 1).trimLeft());
}
