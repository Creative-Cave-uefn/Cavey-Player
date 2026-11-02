import 'package:cave_player/core/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ручные загрузки сохраняются в настройках', () {
    final s = Settings()..offlineTracks = {'a', 'b'};
    final back = Settings.fromJson(s.toJson());
    expect(back.offlineTracks, {'a', 'b'});
  });

  test('старые настройки без загрузок читаются', () {
    final back = Settings.fromJson({'cacheLimitMb': 512});
    expect(back.offlineTracks, isEmpty);
    expect(back.cacheLimitMb, 512);
  });
}
