import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:polka/core/models.dart';
import 'package:polka/core/tags.dart';

Uint8List head(String name) {
  final b = File('test/fixtures/$name').readAsBytesSync();
  return Uint8List.fromList(b.length > 131072 ? b.sublist(0, 131072) : b);
}

Uint8List full(String name) => File('test/fixtures/$name').readAsBytesSync();

void expectCover(String name, PicRef? pic) {
  expect(pic, isNotNull, reason: 'в $name должна найтись обложка');
  final file = full(name);
  final cover = full('cover.jpg');
  expect(file.sublist(pic!.offset, pic.offset + pic.length), cover);
}

void main() {
  group('теги', () {
    test('MP3 ID3v2.3 с обложкой', () {
      final t = parseTags(head('a.mp3'), 'a.mp3');
      expect(t.title, 'Кино тест');
      expect(t.artist, 'Виктор');
      expect(t.album, 'Альбом');
      expect(t.track, 3);
      expectCover('a.mp3', t.pic);
    });

    test('MP3 ID3v2.4 в UTF-8', () {
      final t = parseTags(head('b.mp3'), 'b.mp3');
      expect(t.title, 'UTF8 Title');
      expect(t.artist, 'Арт');
    });

    test('FLAC с обложкой', () {
      final t = parseTags(head('c.flac'), 'c.flac');
      expect(t.title, 'Флак');
      expect(t.artist, 'Группа');
      expect(t.album, 'Диск');
      expectCover('c.flac', t.pic);
    });

    test('Opus', () {
      final t = parseTags(head('d.opus'), 'd.opus');
      expect(t.title, 'Опус');
      expect(t.artist, 'Кто-то');
    });

    test('M4A', () {
      final t = parseTags(head('e.m4a'), 'e.m4a');
      expect(t.title, 'М4А');
      expect(t.artist, 'Некто');
      expect(t.album, 'Ал');
    });

    test('Ogg Vorbis', () {
      final t = parseTags(head('f.ogg'), 'f.ogg');
      expect(t.title, 'Ворбис');
    });

    test('старый MP3 в cp1251', () {
      final title = [0xCA, 0xE8, 0xED, 0xEE, 0x20, 0xF2, 0xE5, 0xF1, 0xF2]; // «Кино тест»
      final frame = [...'TIT2'.codeUnits, 0, 0, 0, title.length + 1, 0, 0, 0, ...title];
      final bytes = Uint8List.fromList([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, frame.length, ...frame, ...List.filled(64, 0)]);
      expect(parseTags(bytes, 'x.mp3').title, 'Кино тест');
    });

    test('без тегов — разбор имени файла', () {
      final t = parseTags(Uint8List(0), '05 - Цой - Звезда по имени Солнце.mp3');
      expect(t.artist, 'Цой');
      expect(t.title, 'Звезда по имени Солнце');
      expect(t.track, 5);
    });

    test('битый файл не роняет разбор', () {
      final junk = Uint8List.fromList([0x49, 0x44, 0x33, 4, 0, 0x40, 0x7f, 0x7f, 0x7f, 0x7f, 1, 2, 3]);
      expect(parseTags(junk, 'Песня.mp3').title, 'Песня');
    });
  });

  group('общая библиотека', () {
    test('операции двух друзей сливаются', () {
      final base = LibraryData();
      final opA = {
        'op': 'createPlaylist',
        'playlist': {'id': 'p1', 'name': 'Дача', 'by': 'a@x', 'at': 1, 'items': <String>[]}
      };
      final opB = {'op': 'like', 'id': 't1', 'email': 'b@x', 'on': true};
      // Друг A сохранил первым, друг B применяет свои операции поверх свежей версии
      final afterA = base.clone()..apply(opA);
      final afterB = afterA.clone()..apply(opB);
      expect(afterB.playlists.single.name, 'Дача');
      expect(afterB.likes['t1'], {'b@x'});
    });

    test('повтор операции ничего не ломает', () {
      final d = LibraryData();
      final op = {'op': 'addToPlaylist', 'id': 'p1', 'items': ['t1']};
      d.apply({
        'op': 'createPlaylist',
        'playlist': {'id': 'p1', 'name': 'X', 'by': '', 'at': 0, 'items': <String>[]}
      });
      d.apply(op);
      d.apply(op);
      expect(d.playlists.single.items, ['t1']);
    });

    test('сериализация туда и обратно', () {
      final d = LibraryData();
      d.apply({
        'op': 'upsertTracks',
        'tracks': {
          'f1': {'s': 'src', 't': 'Трек', 'a': 'Артист', 'p': [10, 20, 'image/jpeg'], 'm': '2026', 'sz': 5}
        }
      });
      final back = LibraryData.fromJson(d.toJson());
      final t = back.tracks['f1']!;
      expect(t.title, 'Трек');
      expect(t.pic!.offset, 10);
      expect(t.displayAlbum, 'Без альбома');
    });
  });
}
