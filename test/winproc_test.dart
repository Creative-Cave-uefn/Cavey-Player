import 'dart:io';

import 'package:cave_player/core/winproc.dart';
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

  test('кавычки в командной строке Windows', () {
    expect(quoteArg('plain'), 'plain');
    expect(quoteArg(''), '""');
    expect(quoteArg('a b'), '"a b"');
    expect(quoteArg('a"b'), r'"a\"b"');
    expect(quoteArg(r'C:\Program Files\x\'), r'"C:\Program Files\x\\"');
    expect(quoteArg('127.0.0.1:51234'), '127.0.0.1:51234');
  });
}
