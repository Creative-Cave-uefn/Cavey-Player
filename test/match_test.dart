import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/library.dart';

void main() {
  test('название без исполнителя в начале и без «remastered»', () {
    expect(LibraryController.titleKey('Korn', 'Korn - Freak On a Leash'), 'freak on a leash');
    expect(LibraryController.titleKey('Korn', 'Freak On a Leash (Remastered 2019)'), 'freak on a leash');
    expect(LibraryController.titleKey('Queen', 'Bohemian Rhapsody - Remastered 2011'), 'bohemian rhapsody');
  });

  test('исполнитель, записанный по-разному', () {
    expect(LibraryController.artistsMatch('Korn', 'KoЯn'), isTrue);
    expect(LibraryController.artistsMatch('The Weeknd', 'Weeknd'), isTrue);
    expect(LibraryController.artistsMatch('Korn', 'Korn feat. Skrillex'), isTrue);
    expect(LibraryController.artistsMatch('Korn', 'Kiss'), isFalse);
  });

  test('ключ дубликата одинаков для «KoЯn» и «Korn»', () {
    expect(LibraryController.dupKey('KoЯn', 'Blind'), LibraryController.dupKey('Korn', 'Blind'));
  });
}
