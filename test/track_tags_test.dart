import 'package:cave_player/core/models.dart';
import 'package:cave_player/core/track_tags.dart';
import 'package:flutter_test/flutter_test.dart';

TagBook book(Map<String, String> edits, {Map<String, String> merged = const {}}) =>
    TagBook('me@x.com', edits, (id) => merged[id] ?? id);

Track _t(String id) =>
    Track(id: id, source: 's', title: id, artist: 'A', album: 'B', albumArtist: '', no: null, year: '', pic: null, cover: null, modified: '', size: 0, by: '', path: '');

void main() {
  test('Имя тега: строчные буквы, без пробелов, решёток и ведущего минуса', () {
    expect(cleanTagName('  #Рок '), 'рок');
    expect(cleanTagName('Ночной Драйв'), 'ночнойдрайв');
    expect(cleanTagName('--Jazz'), 'jazz');
    expect(cleanTagName('a,b|c'), 'abc');
    expect(cleanTagName('x' * 50).length, kTagMaxLen);
  });

  test('Пробел и запятая разделяют теги', () {
    expect(splitTagNames('рок #вечер, Джаз рок'), ['рок', 'вечер', 'джаз']);
    expect(splitTagNames('  # '), isEmpty);
  });

  test('Теги трека читаются из личной записи; удалённый тег пропадает', () {
    final b = book({
      'tg:a': 'рок',
      'tg:b': 'вечер',
      'tg:c': '',
      'tt:t1': 'a:100,b:50,c:10',
      'tt:t2': 'b:70',
    });
    expect(b.all.map((t) => t.name), ['вечер', 'рок']);
    expect(b.tagsOf('t1'), ['b', 'a']); // сначала те, что повесили раньше
    expect(b.tagsOf('t2'), ['b']);
    expect(b.tracksOf('b').map((e) => e.$1).toSet(), {'t1', 't2'});
    expect(b.count('b', (_) => true), 2);
    expect(b.count('a', (id) => id != 't1'), 0);
  });

  test('Дубликаты по имени (два устройства) сливаются в один тег', () {
    final b = book({'tg:a1': 'рок', 'tg:a2': 'рок', 'tt:t1': 'a2:5', 'tt:t2': 'a1:7'});
    expect(b.all.length, 1);
    expect(b.groupOf('a2'), ['a1', 'a2']);
    expect(b.tagsOf('t1'), ['a1']);
    expect(b.tracksOf('a1').length, 2);
  });

  test('Склеенные дубликаты треков объединяют теги', () {
    final b = book({'tg:a': 'рок', 'tg:b': 'вечер', 'tt:old': 'a:1', 'tt:keep': 'b:2'}, merged: {'old': 'keep'});
    expect(b.tagsOf('keep').toSet(), {'a', 'b'});
    expect(b.rawKeysOf('keep').toSet(), {'old', 'keep'});
  });

  test('Запрос: теги, исключение, ИЛИ и обычный текст', () {
    final q = parseTagQuery('#рок #вечер -#грусть nirvana live');
    expect(q.include, ['рок', 'вечер']);
    expect(q.exclude, ['грусть']);
    expect(q.any, isFalse);
    expect(q.text, 'nirvana live');
    expect(parseTagQuery('#рок | #джаз').any, isTrue);
    expect(parseTagQuery('#рок|#джаз').include, ['рок', 'джаз']);
    expect(parseTagQuery('#').active, isFalse);
    expect(parseTagQuery('просто текст').active, isFalse);
  });

  test('Отбор треков по тегам: И, ИЛИ, исключение, недописанный тег', () {
    final b = book({
      'tg:a': 'рок',
      'tg:b': 'вечер',
      'tg:c': 'рокабилли',
      'tt:t1': 'a:1,b:1',
      'tt:t2': 'a:1',
      'tt:t3': 'b:1',
      'tt:t4': 'c:1',
    });
    // Трек в тесте нужен только id: берём настоящий класс
    bool ok(String query, String id) {
      final f = tagFilterFor(b, parseTagQuery(query))!;
      return f(_t(id));
    }

    expect(ok('#рок #вечер', 't1'), isTrue);
    expect(ok('#рок #вечер', 't2'), isFalse);
    expect(ok('#рок | #вечер', 't3'), isTrue);
    expect(ok('#рок -#вечер', 't1'), isFalse);
    expect(ok('#рок -#вечер', 't2'), isTrue);
    // «#ро» ещё набирается: подходят и «рок», и «рокабилли»
    expect(ok('#ро', 't4'), isTrue);
    expect(ok('#ро', 't3'), isFalse);
    // Точное имя не цепляет теги, которые на него только начинаются
    expect(ok('#рок', 't4'), isFalse);
  });
}
