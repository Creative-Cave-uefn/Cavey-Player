import 'package:cave_player/core/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Настройки хранят флаг «без автоподключения» и свою папку cave-data', () {
    final s = Settings()
      ..hubId = 'hub'
      ..libFileId = 'lib'
      ..autoJoinDisabled = true
      ..dataFolderOverride = 'data';
    final back = Settings.fromJson(s.toJson());
    expect(back.autoJoinDisabled, isTrue);
    expect(back.dataFolderOverride, 'data');
    expect(back.hubId, 'hub');
  });

  test('Старые настройки читаются: автоподключение включено, cave-data на обычном месте', () {
    final s = Settings.fromJson({'hubId': 'h', 'libFileId': 'l'});
    expect(s.autoJoinDisabled, isFalse);
    expect(s.dataFolderOverride, isNull);
  });

  test('Плавный переход по умолчанию 3 секунды, медиаклавиши без фокуса включены; значения сохраняются и ограничиваются', () {
    final d = Settings.fromJson({});
    expect(d.crossfadeSec, 3);
    expect(d.globalMediaKeys, isTrue);
    final s = Settings()
      ..crossfadeSec = 7
      ..globalMediaKeys = false;
    final back = Settings.fromJson(s.toJson());
    expect(back.crossfadeSec, 7);
    expect(back.globalMediaKeys, isFalse);
    expect(Settings.fromJson({'crossfadeSec': 99}).crossfadeSec, 10);
    expect(Settings.fromJson({'crossfadeSec': 0}).crossfadeSec, 0);
  });
}
