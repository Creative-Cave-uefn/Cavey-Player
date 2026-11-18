import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/smoke_test.dart';

void main() {
  group('DevKit smoke test', () {
    test('only an explicit report path turns it on', () {
      expect(smokeTestPath(const []), isNull);
      expect(smokeTestPath(const ['--tray']), isNull);
      expect(smokeTestPath(const ['--smoke-test=']), isNull);
      expect(smokeTestPath(const ['--tray', r'--smoke-test=C:\tmp\smoke.json']), r'C:\tmp\smoke.json');
    });

    test('report says what the build is and what worked', () {
      final report = smokeTestReport(mediaKit: true, frame: false, error: 'boom');
      expect(report.keys, containsAll(['version', 'channel', 'mediaKit', 'frame', 'error']));
      expect(report['mediaKit'], true);
      expect(report['frame'], false);
      expect(smokeTestReport(mediaKit: true, frame: true).containsKey('error'), false);
    });
  });
}
