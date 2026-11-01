import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/drive.dart';

Map<String, Object?> folder({
  bool list = true,
  bool remove = true,
  bool add = true,
  bool trash = true,
}) => {
  'capabilities': {
    'canListChildren': list,
    'canRemoveChildren': remove,
    'canAddChildren': add,
    'canTrash': trash,
  },
};

void main() {
  group('merging Google Drive folders without a server', () {
    test('allows the credential that can change both folders', () {
      expect(DriveApi.folderMergePermissionProblem(folder(), folder()), isNull);
    });
    test('rejects read-only source before moving anything', () {
      expect(DriveApi.folderMergePermissionProblem(
        folder(remove: false), folder()), contains('исходной'));
    });
    test('rejects read-only target before moving anything', () {
      expect(DriveApi.folderMergePermissionProblem(
        folder(), folder(add: false)), contains('целевую'));
    });
    test('requires ability to remove the empty source folder', () {
      expect(DriveApi.folderMergePermissionProblem(
        folder(trash: false), folder()), contains('корзину'));
    });
    test('missing capabilities must not be treated as permission', () {
      expect(DriveApi.folderMergePermissionProblem(
        const {}, folder()), isNotNull);
      expect(DriveApi.folderMergePermissionProblem(
        folder(), const {}), isNotNull);
    });
  });
}
