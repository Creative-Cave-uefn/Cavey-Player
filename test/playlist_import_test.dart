import 'package:cave_player/core/dl/sources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Ссылки на плейлисты Яндекс Музыки: старого и нового вида', () {
    expect(yandexPlaylistApiUrl('https://music.yandex.ru/users/ivan/playlists/1003?utm=1'),
        'https://api.music.yandex.net/users/ivan/playlists/1003');
    expect(yandexPlaylistApiUrl('https://music.yandex.ru/playlists/ab12-cd34'), 'https://api.music.yandex.net/playlist/ab12-cd34');
    expect(yandexPlaylistApiUrl('https://music.yandex.ru/album/1'), isNull);
  });
}
