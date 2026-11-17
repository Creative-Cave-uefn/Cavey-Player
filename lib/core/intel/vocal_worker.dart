import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'vocal_activity.dart';

/// Optional local executable: no URL/token argument, network client or audio upload.
class VocalWorker {
  final String executable, model;
  const VocalWorker(this.executable, this.model);
  factory VocalWorker.installed() {
    final root = File(Platform.resolvedExecutable).parent.path;
    return VocalWorker('$root/audio-intelligence/cave-intelligence.exe',
        '$root/audio-intelligence/yamnet.tflite');
  }
  bool get available =>
      File(executable).existsSync() && File(model).existsSync();
  Future<VocalActivity?> analyze(
      File source, String ffmpeg, Directory work) async {
    if (!available) return null;
    final output = File(
        '${work.path}/vocal-${DateTime.now().microsecondsSinceEpoch}.json');
    Process? process;
    try {
      process = await Process.start(
          executable,
          [
            '--model',
            model,
            '--input',
            source.path,
            '--ffmpeg',
            ffmpeg,
            '--output',
            output.path
          ],
          runInShell: false);
      final drained = Future.wait(
          [process.stdout.drain<void>(), process.stderr.drain<void>()]);
      final code = await process.exitCode.timeout(const Duration(seconds: 120));
      await drained;
      if (code != 0 ||
          !output.existsSync() ||
          await output.length() > 256 * 1024) return null;
      return VocalActivity.fromJson(jsonDecode(await output.readAsString()));
    } on TimeoutException {
      process?.kill();
      return null;
    } catch (_) {
      return null;
    } finally {
      try {
        if (output.existsSync()) output.deleteSync();
      } catch (_) {}
    }
  }
}
