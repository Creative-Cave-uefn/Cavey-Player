import 'dart:io';

import 'package:cave_player/core/dl/winproc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('WinProc finds a command by name in Windows PATH', () async {
    if (!Platform.isWindows) return;

    final output = <String>[];
    final exitCode = await WinProc.run('where.exe', ['cmd.exe'], output.add);

    expect(exitCode, 0, reason: output.join('\n'));
    expect(output.any((line) => line.toLowerCase().contains('cmd.exe')), isTrue,
        reason: output.join('\n'));
  });
}
