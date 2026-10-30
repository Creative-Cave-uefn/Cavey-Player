import 'dart:convert';

import 'package:cave_player/core/desktop_notify.dart';
import 'package:cave_player/core/notices.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const me = 'me@x.com';
  final t0 = DateTime.utc(2026, 10, 30, 12);
  String uploader(String id) => id.startsWith('mine') ? me : 'other@x.com';

  List<Notice> run(List<(String, DateTime, Map<String, dynamic>)> events) =>
      collectNotices(me: me, events: events, uploaderOf: uploader);

  test('Лайк чужого трека не касается, лайк моего — уведомление', () {
    final n = run([
      ('a@x.com', t0, {'k': 'like', 'track': 'zzz'}),
      ('a@x.com', t0.add(const Duration(minutes: 1)), {'k': 'like', 'track': 'mine1'}),
    ]);
    expect(n, hasLength(1));
    expect(n.single.kind, NoticeKind.like);
    expect(n.single.trackIds, ['mine1']);
  });

  test('Свои события пропускаются', () {
    expect(run([(me, t0, {'k': 'like', 'track': 'mine1'})]), isEmpty);
  });

  test('Добавление в плейлист: берутся только мои треки; название — если плейлист открытый', () {
    final n = run([
      ('a@x.com', t0, {'k': 'addpl', 'tracks': ['mine1', 'zzz', 'mine2'], 'name': 'Для дороги'}),
      ('b@x.com', t0.add(const Duration(minutes: 1)), {'k': 'addpl', 'tracks': ['mine3']}),
      ('c@x.com', t0, {'k': 'addpl', 'tracks': ['zzz']}),
    ]);
    expect(n, hasLength(2));
    expect(n.first.from, 'b@x.com');
    expect(n.first.playlist, isNull);
    expect(n.last.trackIds, ['mine1', 'mine2']);
    expect(n.last.playlist, 'Для дороги');
  });

  test('«Поделился» приходит только тем, кому адресовано', () {
    final n = run([
      ('a@x.com', t0, {'k': 'share', 'to': [me, 'b@x.com'], 'track': 'zzz', 'note': ' слушай '}),
      ('a@x.com', t0, {'k': 'share', 'to': ['b@x.com'], 'track': 'zzz'}),
    ]);
    expect(n, hasLength(1));
    expect(n.single.note, 'слушай');
    expect(n.single.trackIds, ['zzz']);
  });

  test('Новые — только после отметки; без отметки старое не показывается', () {
    final all = run([
      ('a@x.com', t0, {'k': 'like', 'track': 'mine1'}),
      ('a@x.com', t0.add(const Duration(hours: 1)), {'k': 'like', 'track': 'mine2'}),
    ]);
    expect(freshNotices(all, null), isEmpty);
    expect(freshNotices(all, t0.toIso8601String()), hasLength(1));
    expect(freshNotices(all, t0.add(const Duration(hours: 2)).toIso8601String()), isEmpty);
  });

  test('Тексты уведомлений', () {
    String title(String id) => 'Песня';
    String label(String id) => 'Песня — Автор';
    expect(noticeText(Notice(NoticeKind.like, 'a', t0, ['x']), who: 'Redsit', title: title, label: label),
        'Redsit добавил(а) «Песня» в любимое');
    expect(noticeText(Notice(NoticeKind.addToPlaylist, 'a', t0, ['x'], playlist: 'Дорога'), who: 'Redsit', title: title, label: label),
        'Redsit добавил(а) «Песня» в плейлист «Дорога»');
    expect(noticeText(Notice(NoticeKind.addToPlaylist, 'a', t0, ['x', 'y']), who: 'Redsit', title: title, label: label),
        'Redsit добавил(а) ваших треков: 2 в плейлист');
    expect(noticeText(Notice(NoticeKind.share, 'a', t0, ['x']), who: 'Danila', title: title, label: label),
        'Danila поделился(ась): Песня — Автор');
  });

  test('Уведомление Windows: текст экранируется, команда кодируется в UTF-16', () {
    final script = toastScript('Cave Player', 'Вася <b> & "Петя\'s"');
    expect(script, contains('&lt;b&gt; &amp; &quot;Петя&apos;s&quot;'));
    final enc = encodePowerShell('aб');
    expect(base64Decode(enc), [0x61, 0x00, 0x31, 0x04]);
  });
}
