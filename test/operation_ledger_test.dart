import 'package:cave_player/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Shared library persists applied operation IDs through JSON round-trip', () {
    final data = LibraryData();
    final op = <String, dynamic>{
      'oid': 'client-123:1',
      'op': 'setMeta',
      'meta': <String, dynamic>{
        'u:friend@example.org': <String, String>{'nick': 'Alice'},
      },
    };
    data.apply(op);
    expect(data.edits['u:friend@example.org']?['nick'], 'Alice');
    expect(data.appliedOps.containsKey('client-123:1'), isTrue);
    final loaded = LibraryData.fromJson(data.toJson());
    expect(loaded.appliedOps.containsKey('client-123:1'), isTrue);
    expect(loaded.edits['u:friend@example.org']?['nick'], 'Alice');
  });

  test('Previously applied operation cannot overwrite a newer edit twice', () {
    final data = LibraryData();
    data.apply(<String, dynamic>{
      'oid': 'client-123:1',
      'op': 'setMeta',
      'meta': {'u:friend@example.org': {'nick': 'Alice'}},
    });
    data.apply(<String, dynamic>{
      'oid': 'client-987:2',
      'op': 'setMeta',
      'meta': {'u:friend@example.org': {'nick': 'Bob'}},
    });
    data.apply(<String, dynamic>{
      'oid': 'client-123:1',
      'op': 'setMeta',
      'meta': {'u:friend@example.org': {'nick': 'Alice'}},
    });
    expect(data.edits['u:friend@example.org']?['nick'], 'Bob');
  });

  test('Recent operation absent in a stale snapshot can be replayed', () {
    final op = <String, dynamic>{
      'oid': 'client-123:1',
      'op': 'like',
      'id': 'song1',
      'email': 'listener@example.org',
      'on': true,
      'ts': 12345,
    };
    final stale = LibraryData();
    expect(stale.appliedOps.containsKey(op['oid']), isFalse);
    stale.apply(op);
    stale.apply(op);
    expect(stale.likes['song1'], {'listener@example.org'});
    expect(stale.likeTimes['song1|listener@example.org'], 12345);
  });
}
