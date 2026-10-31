// Выбор загрузчика в настройках. Сам Sockseek теперь в модуле cave-downloader, его тесты там.
import 'package:cave_player/core/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Sockseek migration and independent active source choice', () {
    final old = Settings.fromJson({'useSockseek': true, 'useZotify': true});
    expect(old.downloadProvider, 'sockseek');
    final ignoredZotify = Settings.fromJson({'useZotify': true});
    expect(ignoredZotify.downloadProvider, 'youtube');
    final chosen = Settings()..downloadProvider = 'bandcamp';
    expect(Settings.fromJson(chosen.toJson()).downloadProvider, 'bandcamp');
    expect(chosen.toJson().containsKey('useZotify'), isFalse);
    expect(Settings.fromJson({'downloadProvider': 'unexpected'}).downloadProvider, 'youtube');
  });
}
