import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/dl/deezer.dart';
import 'package:cave_player/core/dl/sockseek.dart';
import 'package:cave_player/core/dl/tools.dart';

void main() {
  late Directory temp;
  late Tools tools;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cave-provider-config-');
    tools = Tools(temp);
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('creates local Deezer and Soulseek configs without user input', () async {
    await DeezerMusic.prepareConfig(tools);
    await Sockseek.prepareConfig(tools);
    final deezer = await DeezerMusic.config(tools).readAsString();
    final soulseek = await Sockseek.config(tools).readAsString();
    expect(deezer, contains('[deezer]'));
    expect(deezer, contains('arl = '));
    expect(soulseek, contains('username = '));
    expect(soulseek, contains('password = '));
  });

  test('does not overwrite a user-authored Deezer ARL', () async {
    const initial = '[deezer]\narl = a_custom_user_value\nquality = mp3\n';
    final f = DeezerMusic.config(tools);
    await f.writeAsString(initial);
    await DeezerMusic.prepareConfig(tools);
    expect(await f.readAsString(), initial);
  });

  test('does not overwrite user-authored Soulseek credentials', () async {
    const initial = 'username = my_local_user\npassword = my_local_password\n';
    final f = Sockseek.config(tools);
    await f.writeAsString(initial);
    await Sockseek.prepareConfig(tools);
    expect(await f.readAsString(), initial);
  });
}
