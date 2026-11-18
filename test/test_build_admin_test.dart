import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/test_build_admin.dart';
import 'package:cave_player/core/updater.dart';

BuildInfo build(String branch, String version) => BuildInfo(
      version: version,
      branch: branch,
      slug: Updater.slugOf(branch),
      notes: '',
      published: null,
      url: '',
      size: 1,
    );

void main() {
  group('test release cleanup safety', () {
    test('accepts only precise test tags', () {
      expect(TestBuildAdmin.isSafeTestTag('test-claude-dj-v2-v0.4.0.123'), true);
      expect(TestBuildAdmin.isSafeTestTag('v0.4.0'), false);
      expect(TestBuildAdmin.isSafeTestTag('beta-v0.4.0'), false);
      expect(TestBuildAdmin.isSafeTestTag('android-v1.0.40'), false);
      expect(TestBuildAdmin.isSafeTestTag('test-channel-v123'), false);
      expect(TestBuildAdmin.isSafeTestTag('test-channel-v0.4.0;rm'), false);
    });

    test('keeps the newest build per branch', () {
      final entries = [
        build('feat/a', '0.4.0.3'),
        build('feat/a', '0.4.0.1'),
        build('feat/b', '0.4.0.4'),
        build('feat/b', '0.4.0.2'),
        build('feat/c', '0.4.0.7'),
      ];
      final stale = TestBuildAdmin.staleBuilds(entries);
      expect(stale.map((b) => TestBuildAdmin.tagOf(b)).toSet(), {
        'test-feat-a-v0.4.0.1',
        'test-feat-b-v0.4.0.2',
      });
    });

    test('DevKit channels keep three versions for rollback', () {
      final entries = [
        for (final n in [5, 4, 3, 2, 1]) build('devkit/dj/20261118', '0.4.0.$n'),
        build('feat/a', '0.4.0.9'),
        build('feat/a', '0.4.0.8'),
      ];
      final stale = TestBuildAdmin.staleBuilds(entries);
      expect(stale.map((b) => TestBuildAdmin.tagOf(b)).toSet(), {
        'test-devkit-dj-20261118-v0.4.0.2',
        'test-devkit-dj-20261118-v0.4.0.1',
        'test-feat-a-v0.4.0.8',
      });
    });

    test('never schedules installed build for mass deletion', () {
      final entries = [
        build('feat/a', '0.4.0.3'),
        build('feat/a', '0.4.0.2'),
        build('feat/a', '0.4.0.1'),
      ];
      final stale = TestBuildAdmin.staleBuilds(entries,
          protectedTag: 'test-feat-a-v0.4.0.1');
      expect(stale.map((b) => b.version).toList(), ['0.4.0.2']);
    });
  });
}
