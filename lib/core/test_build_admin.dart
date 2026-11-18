import 'dart:convert';
import 'dart:io';

import '../config.dart' show kReleasesRepo;
import 'updater.dart';

/// Developer-only operations. Never stores or embeds GitHub credentials.
class TestBuildAdmin {
  static final RegExp _testTag = RegExp(r'^test-[a-z0-9-]+-v\d+(?:\.\d+)+$');

  static bool isSafeTestTag(String tag) => _testTag.hasMatch(tag);

  static String tagOf(BuildInfo build) => 'test-${build.slug}-v${build.version}';

  /// Versions kept per DevKit channel (`devkit-*` slugs) as rollback targets.
  /// Must match `$script:KeepPerChannel` in tools/cavey-devkit-engine.ps1.
  static const devKitKeep = 3;

  /// How many versions of a channel survive cleanup: DevKit channels keep
  /// [devKitKeep] for rollback, CI branch channels keep only the newest.
  static int keepFor(String slug) => slug.startsWith('devkit-') ? devKitKeep : 1;

  /// Keep the latest releases per update channel and protect the running one.
  static List<BuildInfo> staleBuilds(List<BuildInfo> builds, {String? protectedTag}) {
    final bySlug = <String, List<BuildInfo>>{};
    for (final build in builds) {
      if (build.stable || !isSafeTestTag(tagOf(build))) continue;
      bySlug.putIfAbsent(build.slug, () => []).add(build);
    }
    final stale = <BuildInfo>[];
    for (final group in bySlug.values) {
      group.sort((a, b) {
        if (Updater.isNewer(a.version, b.version)) return -1;
        if (Updater.isNewer(b.version, a.version)) return 1;
        return (b.published ?? DateTime(1970))
            .compareTo(a.published ?? DateTime(1970));
      });
      for (final build in group.skip(keepFor(group.first.slug))) {
        if (tagOf(build) != protectedTag) stale.add(build);
      }
    }
    return stale;
  }

  static Future<void> delete(BuildInfo build) async {
    final tag = tagOf(build);
    if (!Platform.isWindows || build.stable || !isSafeTestTag(tag)) {
      throw StateError('Разрешено удалять только тестовые сборки на Windows.');
    }
    ProcessResult checked;
    try {
      checked = await Process.run('gh', [
        'release', 'view', tag, '--repo', kReleasesRepo,
        '--json', 'tagName,isPrerelease',
      ]);
    } on ProcessException {
      throw StateError('Установите GitHub CLI (gh) и выполните gh auth login.');
    }
    if (checked.exitCode != 0) {
      throw StateError('Нет доступа к GitHub Release. Проверьте gh auth login.');
    }
    final payload = jsonDecode('${checked.stdout}');
    if (payload is! Map ||
        payload['tagName'] != tag ||
        payload['isPrerelease'] != true) {
      throw StateError('Проверка тестового релиза не пройдена.');
    }
    final removed = await Process.run('gh', [
      'release', 'delete', tag, '--repo', kReleasesRepo,
      '--cleanup-tag', '--yes',
    ]);
    if (removed.exitCode != 0) {
      throw StateError('Не удалось удалить $tag: ${removed.stderr}');
    }
  }
}
