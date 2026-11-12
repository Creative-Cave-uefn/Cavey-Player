import 'package:cave_player/core/share_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Ссылка на трек туда и обратно', () {
    final link = appLinkFor('1AbC_d-9');
    expect(link, 'caveplayer://track/1AbC_d-9');
    expect(trackIdFromLink(link), '1AbC_d-9');
    expect(trackIdFromLink(' CavePlayer://track/xyz/ '), 'xyz');
    expect(trackIdFromLink('caveplayer:track/xyz'), 'xyz');
  });

  test('Ссылка для мессенджеров ведёт на страницу-переадресацию и читается обратно', () {
    final web = webLinkFor('abc', base: 'https://example.github.io/app/open');
    expect(web, 'https://example.github.io/app/open/?t=abc');
    expect(trackIdFromLink(web!), 'abc');
    expect(webLinkFor('abc', base: ''), isNull);
  });

  test('Без переменной сборки ссылка для мессенджеров всё равно есть', () {
    final web = webLinkFor('abc');
    expect(web, isNotNull);
    expect(web!.startsWith(kDefaultShareUrl), isTrue);
    expect(trackIdFromLink(web), 'abc');
  });

  test('Чужие и испорченные ссылки не принимаются', () {
    expect(trackIdFromLink('https://example.com/'), isNull);
    expect(trackIdFromLink('caveplayer://album/abc'), isNull);
    expect(trackIdFromLink('caveplayer://track/a b'), isNull);
    expect(trackIdFromLink('https://x.y/?t=a%20b'), isNull);
    expect(trackIdFromLink(''), isNull);
  });

  test('Ссылка находится среди аргументов запуска', () {
    expect(linkFromArgs(['--foo', 'caveplayer://track/abc']), 'caveplayer://track/abc');
    expect(linkFromArgs(['--foo']), isNull);
  });

  test('Ссылки на альбом, исполнителя и плейлист туда и обратно', () {
    final album = appShareLink(ShareKind.album, 'Daft Punk|Discovery / 2001');
    expect(shareTargetFromLink(album), const ShareTarget(ShareKind.album, 'Daft Punk|Discovery / 2001'));
    final artist = appShareLink(ShareKind.artist, 'тату');
    expect(artist.startsWith('caveplayer://artist/'), isTrue);
    expect(shareTargetFromLink(artist), const ShareTarget(ShareKind.artist, 'тату'));
    expect(shareTargetFromLink(appShareLink(ShareKind.playlist, 'plabc12')), const ShareTarget(ShareKind.playlist, 'plabc12'));
    expect(shareTargetFromLink(appShareLink(ShareKind.track, 'xyz')), const ShareTarget(ShareKind.track, 'xyz'));
  });

  test('Ссылки для мессенджеров на альбом, исполнителя и плейлист читаются обратно', () {
    for (final t in const [
      ShareTarget(ShareKind.album, 'A & B|Лучшее: №1'),
      ShareTarget(ShareKind.artist, 'a&b c/d'),
      ShareTarget(ShareKind.playlist, 'pl1x'),
      ShareTarget(ShareKind.track, 'trk_1'),
    ]) {
      final web = webShareLink(t.kind, t.key, base: 'https://example.github.io/app/open/');
      expect(web, isNotNull);
      expect(shareTargetFromLink(web!), t, reason: web);
    }
    expect(webShareLink(ShareKind.album, 'x', base: ''), isNull);
    expect(shareLinkText(ShareKind.album, 'x').startsWith(kDefaultShareUrl), isTrue);
  });

  test('Ссылка на альбом не принимается за ссылку на трек', () {
    expect(trackIdFromLink(appShareLink(ShareKind.album, 'abc')), isNull);
    expect(shareTargetFromLink('caveplayer://playlist/a b'), isNull);
    expect(shareTargetFromLink('caveplayer://album/'), isNull);
    expect(shareTargetFromLink('https://x.y/?pl=a%20b'), isNull);
  });
}
