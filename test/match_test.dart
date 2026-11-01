import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/library.dart';
import 'package:cave_player/core/models.dart';

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

  Track track(String id, String album, {int? durationMs}) {
    final t = Track(
      id: id, source: 'library', title: 'Silver Will', artist: 'Falcom Sound Team',
      album: album, albumArtist: 'Falcom Sound Team', no: 1, year: '',
      pic: null, cover: null, modified: '', size: 100, by: '', path: '',
    );
    t.durationMs = durationMs;
    return t;
  }

  test('Trails in the Sky: одно имя и исполнитель, но разные альбомы', () {
    final fc = track('fc', 'Trails in the Sky FC', durationMs: 124000);
    final sc = track('sc', 'Trails in the Sky SC', durationMs: 126000);
    expect(LibraryController.dupKey(fc.artist, fc.title),
        LibraryController.dupKey(sc.artist, sc.title));
    expect(LibraryController.recordingKey(fc), isNot(LibraryController.recordingKey(sc)));
    expect(LibraryController.matchesRecording(fc, album: sc.album), isFalse);
    expect(LibraryController.matchesRecording(sc, album: sc.album), isTrue);
  });

  test('длительность отличает разные аранжировки, неизвестная длительность не даёт ложной уверенности', () {
    final known = track('known', 'Trails FC', durationMs: 184000);
    final unknown = track('unknown', 'Trails FC');
    expect(LibraryController.matchesRecording(known, album: 'Trails FC', duration: 200), isFalse);
    expect(LibraryController.matchesRecording(known, album: 'trails fc', duration: 185), isTrue);
    expect(LibraryController.matchesRecording(unknown, duration: 185), isFalse);
    expect(LibraryController.matchesRecording(unknown, album: 'Trails FC', duration: 185), isTrue);
  });
}
