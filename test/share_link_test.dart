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
}
