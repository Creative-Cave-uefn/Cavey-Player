// Запуск консольных программ на Windows без окон: CreateProcessW с флагом
// CREATE_NO_WINDOW, как subprocess в Python. У процесса есть скрытая консоль,
// и всё, что он запускает сам (yt-dlp → ffmpeg, Deno), тоже остаётся невидимым.
// Вывод читается в отдельном изоляте, чтобы не подвешивать интерфейс.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _SecurityAttributes extends Struct {
  @Uint32()
  external int nLength;
  external Pointer<Void> lpSecurityDescriptor;
  @Int32()
  external int bInheritHandle;
}

final class _StartupInfo extends Struct {
  @Uint32()
  external int cb;
  external Pointer<Utf16> lpReserved;
  external Pointer<Utf16> lpDesktop;
  external Pointer<Utf16> lpTitle;
  @Uint32()
  external int dwX;
  @Uint32()
  external int dwY;
  @Uint32()
  external int dwXSize;
  @Uint32()
  external int dwYSize;
  @Uint32()
  external int dwXCountChars;
  @Uint32()
  external int dwYCountChars;
  @Uint32()
  external int dwFillAttribute;
  @Uint32()
  external int dwFlags;
  @Uint16()
  external int wShowWindow;
  @Uint16()
  external int cbReserved2;
  external Pointer<Uint8> lpReserved2;
  @IntPtr()
  external int hStdInput;
  @IntPtr()
  external int hStdOutput;
  @IntPtr()
  external int hStdError;
}

final class _ProcessInfo extends Struct {
  @IntPtr()
  external int hProcess;
  @IntPtr()
  external int hThread;
  @Uint32()
  external int dwProcessId;
  @Uint32()
  external int dwThreadId;
}

/// Правила кавычек Windows (как их понимает CommandLineToArgvW)
String quoteArg(String a) {
  if (a.isNotEmpty && !RegExp(r'[\s"]').hasMatch(a)) return a;
  final sb = StringBuffer('"');
  var slashes = 0;
  for (final r in a.runes) {
    final c = String.fromCharCode(r);
    if (c == r'\') {
      slashes++;
      continue;
    }
    if (c == '"') {
      sb.write(r'\' * (slashes * 2 + 1));
      sb.write('"');
      slashes = 0;
      continue;
    }
    if (slashes > 0) {
      sb.write(r'\' * slashes);
      slashes = 0;
    }
    sb.write(c);
  }
  sb.write(r'\' * (slashes * 2));
  sb.write('"');
  return sb.toString();
}

class WinProc {
  /// Запускает программу и отдаёт её вывод (stdout и stderr вместе) построчно
  static Future<int> run(String exe, List<String> args, void Function(String line) onLine,
      {void Function(int pid)? onStarted}) async {
    final port = ReceivePort();
    final bytes = StreamController<List<int>>();
    final exit = Completer<int>();
    port.listen((msg) {
      if (msg is Uint8List) {
        bytes.add(msg);
      } else if (msg is List && msg.length == 2 && msg.first == 'started') {
        onStarted?.call(msg[1] as int);
      } else if (msg is List && msg.isNotEmpty && msg.first == 'exit') {
        exit.complete(msg[1] as int);
        bytes.close();
        port.close();
      }
    });
    final lines = bytes.stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach(onLine);
    await Isolate.spawn(_worker, [port.sendPort, exe, quoteArg(exe), ...args.map(quoteArg)]);
    final code = await exit.future;
    await lines;
    return code;
  }
}

typedef _LastErrorC = Uint32 Function();
typedef _LastErrorD = int Function();

typedef _CreatePipeC = Int32 Function(Pointer<IntPtr>, Pointer<IntPtr>, Pointer<_SecurityAttributes>, Uint32);
typedef _CreatePipeD = int Function(Pointer<IntPtr>, Pointer<IntPtr>, Pointer<_SecurityAttributes>, int);
typedef _SetHandleInfoC = Int32 Function(IntPtr, Uint32, Uint32);
typedef _SetHandleInfoD = int Function(int, int, int);
typedef _CreateFileC = IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<_SecurityAttributes>, Uint32, Uint32, IntPtr);
typedef _CreateFileD = int Function(Pointer<Utf16>, int, int, Pointer<_SecurityAttributes>, int, int, int);
typedef _CreateProcessC = Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>, Pointer<Void>, Int32, Uint32,
    Pointer<Void>, Pointer<Utf16>, Pointer<_StartupInfo>, Pointer<_ProcessInfo>);
typedef _CreateProcessD = int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>, Pointer<Void>, int, int, Pointer<Void>,
    Pointer<Utf16>, Pointer<_StartupInfo>, Pointer<_ProcessInfo>);
typedef _ReadFileC = Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>);
typedef _ReadFileD = int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>);
typedef _WaitC = Uint32 Function(IntPtr, Uint32);
typedef _WaitD = int Function(int, int);
typedef _ExitCodeC = Int32 Function(IntPtr, Pointer<Uint32>);
typedef _ExitCodeD = int Function(int, Pointer<Uint32>);
typedef _CloseC = Int32 Function(IntPtr);
typedef _CloseD = int Function(int);
typedef _SetEnvC = Int32 Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _SetEnvD = int Function(Pointer<Utf16>, Pointer<Utf16>);

/// Работает в отдельном изоляте: создаёт процесс и читает его вывод до конца
void _worker(List<Object?> msg) {
  final port = msg[0] as SendPort;
  final exe = msg[1] as String;
  final cmd = msg.skip(2).cast<String>().join(' ');

  final k32 = DynamicLibrary.open('kernel32.dll');
  final lastError = k32.lookupFunction<_LastErrorC, _LastErrorD>('GetLastError');
  void report(String message) => port.send(Uint8List.fromList(utf8.encode('$message\n')));
  final createPipe = k32.lookupFunction<_CreatePipeC, _CreatePipeD>('CreatePipe');
  final setHandleInfo = k32.lookupFunction<_SetHandleInfoC, _SetHandleInfoD>('SetHandleInformation');
  final createFile = k32.lookupFunction<_CreateFileC, _CreateFileD>('CreateFileW');
  final createProcess = k32.lookupFunction<_CreateProcessC, _CreateProcessD>('CreateProcessW');
  final readFile = k32.lookupFunction<_ReadFileC, _ReadFileD>('ReadFile');
  final wait = k32.lookupFunction<_WaitC, _WaitD>('WaitForSingleObject');
  final exitCode = k32.lookupFunction<_ExitCodeC, _ExitCodeD>('GetExitCodeProcess');
  final close = k32.lookupFunction<_CloseC, _CloseD>('CloseHandle');
  final setEnv = k32.lookupFunction<_SetEnvC, _SetEnvD>('SetEnvironmentVariableW');

  final arena = Arena();
  try {
    // yt-dlp — программа на Python: просим её писать в UTF-8
    setEnv('PYTHONUTF8'.toNativeUtf16(allocator: arena), '1'.toNativeUtf16(allocator: arena));
    setEnv('PYTHONIOENCODING'.toNativeUtf16(allocator: arena), 'utf-8'.toNativeUtf16(allocator: arena));

    final sa = arena<_SecurityAttributes>();
    sa.ref
      ..nLength = sizeOf<_SecurityAttributes>()
      ..lpSecurityDescriptor = nullptr
      ..bInheritHandle = 1;
    final hRead = arena<IntPtr>();
    final hWrite = arena<IntPtr>();
    if (createPipe(hRead, hWrite, sa, 0) == 0) {
      report('CreatePipe: Windows error ${lastError()}');
      port.send(['exit', -1]);
      return;
    }
    setHandleInfo(hRead.value, 1, 0); // наш конец канала дочерним процессам не передаём
    final nul = createFile('NUL'.toNativeUtf16(allocator: arena), 0x80000000, 3, sa, 3, 0, 0);

    final si = arena<_StartupInfo>();
    si.ref
      ..cb = sizeOf<_StartupInfo>()
      ..dwFlags = 0x100 | 0x1 // STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW
      ..wShowWindow = 0 // SW_HIDE
      ..hStdInput = nul
      ..hStdOutput = hWrite.value
      ..hStdError = hWrite.value;
    final pi = arena<_ProcessInfo>();
    // lpApplicationName == nullptr позволяет Windows найти exe через PATH,
    // если это имя вроде python.exe или py.exe (а не абсолютный путь).
    // cmd уже содержит правильно заключённое в кавычки имя программы.
    final ok = createProcess(
      nullptr,
      cmd.toNativeUtf16(allocator: arena),
      nullptr,
      nullptr,
      1,
      0x08000000 | 0x00000400, // CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT
      nullptr,
      nullptr,
      si,
      pi,
    );
    final startError = ok == 0 ? lastError() : 0;
    close(hWrite.value); // иначе чтение не закончится
    if (nul != -1) close(nul);
    if (ok == 0) {
      report('Не удалось запустить $exe: Windows error $startError');
      close(hRead.value);
      port.send(['exit', -1]);
      return;
    }
    // Report the exact process so a cancelled download can stop its entire
    // subprocess tree (including Python/yt-dlp/Soulseek) via taskkill /T.
    port.send(['started', pi.ref.dwProcessId]);

    final buf = arena<Uint8>(65536);
    final got = arena<Uint32>();
    while (readFile(hRead.value, buf, 65536, got, nullptr) != 0 && got.value > 0) {
      port.send(Uint8List.fromList(buf.asTypedList(got.value)));
    }
    close(hRead.value);

    wait(pi.ref.hProcess, 0xFFFFFFFF);
    final code = arena<Uint32>();
    exitCode(pi.ref.hProcess, code);
    close(pi.ref.hProcess);
    close(pi.ref.hThread);
    port.send(['exit', code.value]);
  } catch (e) {
    report('Ошибка запуска $exe: $e');
    port.send(['exit', -1]);
  } finally {
    arena.releaseAll();
  }
}
