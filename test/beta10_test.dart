import 'package:cave_player/core/broker.dart';
import 'package:cave_player/core/drive.dart';
import 'package:cave_player/core/models.dart';
import 'package:cave_player/core/upload_queue.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> file(Map<String, dynamic> extra) => {
      'id': 'f1',
      'name': 'a.mp3',
      'mimeType': 'audio/mpeg',
      'size': '123',
      'createdTime': '2026-01-01T00:00:00Z',
      'owners': [
        {'emailAddress': 'owner@mail', 'displayName': 'Owner'}
      ],
      ...extra,
    };

void main() {
  group('Загрузивший файл', () {
    test('у файла из брокера берётся cave_uploader, а не владелец на Диске', () {
      final f = DriveFile.fromJson(file({
        'properties': {'cave_uploader': 'Friend@Mail', 'cave_source': 'deezer', 'cave_uploaded_at': '2026-02-02T10:00:00Z'},
      }));
      expect(f.ownerEmail, 'owner@mail');
      expect(f.viaBroker, isTrue);
      expect(f.uploaderEmail, 'friend@mail');
      expect(f.uploadSource, 'deezer');
      expect(f.uploadedAt, '2026-02-02T10:00:00Z');
    });

    test('у старого файла без свойства загрузил его владелец', () {
      final f = DriveFile.fromJson(file({}));
      expect(f.viaBroker, isFalse);
      expect(f.uploaderEmail, 'owner@mail');
      expect(f.uploadSource, '');
      expect(f.uploadedAt, '2026-01-01T00:00:00Z');
    });

    test('пустое свойство не считается загрузившим', () {
      final f = DriveFile.fromJson(file({'properties': {'cave_uploader': '  '}}));
      expect(f.viaBroker, isFalse);
      expect(f.uploaderEmail, 'owner@mail');
    });

    test('новые поля трека сохраняются и читаются, старые записи без них читаются', () {
      final t = Track.fromJson('x', {'s': 'src', 't': 'T', 'm': '', 'sz': 1, 'by': 'a@b', 'ua': '2026-02-02', 'us': 'soulseek'});
      expect(t.uploadedAt, '2026-02-02');
      expect(t.uploadSource, 'soulseek');
      expect(Track.fromJson('x', t.toJson()).uploadSource, 'soulseek');
      final old = Track.fromJson('y', {'s': 'src', 't': 'T', 'm': '', 'sz': 1, 'by': 'a@b'});
      expect(old.uploadedAt, '');
      expect(old.toJson().containsKey('us'), isFalse);
    });
  });

  group('Настройки брокера', () {
    test('config.json: адрес берётся только https', () {
      expect(BrokerConfig.fromJson({'broker': 'https://script.google.com/x/exec'})?.url, 'https://script.google.com/x/exec');
      expect(BrokerConfig.fromJson({'broker': 'http://x'}), isNull);
      expect(BrokerConfig.fromJson({}), isNull);
      expect(BrokerConfig.fromJson('мусор'), isNull);
    });

    test('сравнение версий', () {
      expect(BrokerConfig.isNewer('0.10.0', '0.9.5'), isTrue);
      expect(BrokerConfig.isNewer('1.0', '1.0.0'), isFalse);
      expect(BrokerConfig.isNewer('0.9.0', '0.9.0-beta.3'), isFalse);
      expect(BrokerConfig.isNewer('2.0.0', '1.99.99'), isTrue);
    });

    test('какие ошибки стоит ждать в очереди', () {
      expect(const BrokerException('unavailable', '').deferrable, isTrue);
      expect(const BrokerException('owner_full', '').deferrable, isTrue);
      expect(const BrokerException('not_member', '').deferrable, isFalse);
      expect(const BrokerException('too_big', '').deferrable, isFalse);
      expect(const BrokerException('owner_full', '').quickRetry, isFalse);
    });

    test('MIME по расширению', () {
      expect(UploadBroker.mimeFor('a.FLAC'), 'audio/flac');
      expect(UploadBroker.mimeFor('b.jpg'), 'image/jpeg');
      expect(UploadBroker.mimeFor('noext'), 'application/octet-stream');
    });
  });

  group('Очередь «Ожидают загрузки»', () {
    test('запись переживает сохранение в JSON', () {
      final p = PendingUpload(
        id: '1',
        path: 'C:/x/1-a.mp3',
        name: 'a.mp3',
        sourceId: 's',
        folderId: 'f',
        relPath: 'Альбом',
        uploadSource: 'deezer',
        lastError: 'нет связи',
        edit: {'t': 'Название'},
      );
      final back = PendingUpload.fromJson(p.toJson())!;
      expect(back.name, 'a.mp3');
      expect(back.uploadSource, 'deezer');
      expect(back.edit, {'t': 'Название'});
      expect(PendingUpload.fromJson({'id': 1}), isNull);
    });
  });

  group('Причина удаления', () {
    Map<String, dynamic> t(String title) => {'s': 'src', 't': title, 'a': 'A', 'm': '', 'sz': 1};

    test('причина и снимок трека доходят до загрузившего и снимаются после удаления', () {
      final d = LibraryData()
        ..apply({'op': 'upsertTracks', 'tracks': {'x': t('X'), 'k': t('Keep')}})
        ..apply({
          'op': 'deleteTracks',
          'ids': {'x': 'owner@mail'},
          'by': 'friend@mail',
          'info': {
            'x': {
              'k': 'dup',
              'note': 'то же самое',
              't': t('X'),
              'keep': {'id': 'k', 't': t('Keep')},
            }
          },
        });
      expect(d.deletedInfo['x']!['k'], 'dup');
      expect(d.deletedBy['x'], 'friend@mail');
      final copy = LibraryData.fromJson(d.toJson());
      expect(copy.deletedInfo['x']!['note'], 'то же самое');
      d.apply({'op': 'purged', 'ids': ['x']});
      expect(d.deletedInfo, isEmpty);
    });

    test('старое удаление без причины по-прежнему работает', () {
      final d = LibraryData()
        ..apply({'op': 'upsertTracks', 'tracks': {'x': t('X')}})
        ..apply({'op': 'deleteTracks', 'ids': {'x': 'owner@mail'}});
      expect(d.deleted, {'x': 'owner@mail'});
      expect(d.deletedInfo, isEmpty);
    });
  });
}
