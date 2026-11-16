// LLDB as the app offers it (lib/debug/adapters): this machine's lldb-dap
// found as the app finds it and started in the login shell's environment,
// a launch, an attach to a process picked (`${command:pickProcess}`), and
// the program run in a terminal: on one of the IDE's on macOS, by
// lldb-dap's own `runInTerminal` on Linux. Opt in with
// `flutter test --run-skipped -t exthost test/debug/real`.
@Tags(['exthost'])
library;

import 'dart:async';
import 'dart:io';

import 'package:baocode/base/uri.dart' show VsUri;
import 'package:baocode/debug/adapters/lldb_dap.dart';
import 'package:baocode/debug/adapters/lldb_dap_locator.dart';
import 'package:baocode/debug/adapters/native_debugger.dart';
import 'package:baocode/debug/common/debug_model.dart';
import 'package:baocode/debug/common/debug_storage.dart';
import 'package:baocode/debug/common/debug_types.dart';
import 'package:baocode/debug/service/debug_configuration_manager.dart';
import 'package:baocode/debug/service/debug_service.dart';
import 'package:baocode/ide/debug_terminal.dart';
import 'package:baocode/ide/terminal/pty_io.dart';
import 'package:baocode/ide/terminal/terminal_instance.dart';
import 'package:baocode/ide/terminal/terminal_service.dart';
import 'package:baocode/platform/child_process_registry.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_debug_adapter.dart';
import 'support/real_adapter.dart';

final String? _clang = findExecutable('clang');

/// What [terminal]'s screen shows: its lines, wrapped ones joined.
String _screen(TerminalInstance terminal) {
  final lines = terminal.terminal.buffer.lines;
  final text = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    final line = lines.get(i)!;
    if (i > 0 && !line.isWrapped) text.write('\n');
    text.write(line.translateToString(true));
  }
  return text.toString();
}

String _fixture(String name) =>
    File('test/debug/real/fixtures/lldb/$name').absolute.path;

void main() {
  late Directory dir;
  String? lldbDap;
  Object skip = false;

  setUpAll(() async {
    lldbDap = await locateLldbDap();
    skip = lldbDap == null
        ? 'lldb-dap not found'
        : _clang == null
        ? 'clang not found'
        : false;
    if (skip != false) return;
    dir = await Directory.systemTemp.createTemp('baocode-lldb-native-');
    for (final name in const ['program', 'waiter']) {
      final r = await Process.run(_clang!, [
        '-g',
        '-O0',
        '-o',
        '${dir.path}/$name',
        _fixture('$name.c'),
      ]);
      if (r.exitCode != 0) fail('clang failed: ${r.stderr}');
    }
  });

  tearDownAll(() async {
    if (skip != false) return;
    await dir.delete(recursive: true);
  });

  /// A service with the app's LLDB, in [dir].
  Future<({DebugService service, FakeDebugHost host})> debug({
    RunInTerminal? runInTerminal,
    OpenDebugTerminal? openTerminal,
  }) async {
    final host = FakeDebugHost(
      folders: [
        DebugWorkspaceFolder(uri: VsUri.file(dir.path), name: 'real', index: 0),
      ],
    );
    final service = DebugService(
      host: host,
      storage: MemoryDebugStorageBackend(),
      fileStore: MemoryLaunchFileStore(),
    );
    registerNativeDebuggers(
      service,
      const [LldbDapDebugger()],
      runInTerminal: runInTerminal,
      openTerminal: openTerminal,
    );
    await service.configurationManager.initialize();
    addTearDown(() async {
      if (service.model.getSessions().isNotEmpty) {
        await service.stopSession(null);
        try {
          await until(
            () => service.model.getSessions().isEmpty,
            timeout: const Duration(seconds: 15),
          );
        } on TimeoutException {
          // Disposed below anyway.
        }
      }
      service.dispose();
    });
    return (service: service, host: host);
  }

  Future<StackFrame> stopAt(
    DebugService service,
    FakeDebugHost host,
    int line,
  ) async {
    try {
      await until(() {
        final frame = service.viewModel.focusedStackFrame;
        final thread = service.viewModel.focusedThread;
        return frame != null &&
            thread != null &&
            thread.stopped &&
            frame.range.startLineNumber == line;
      }, timeout: const Duration(seconds: 30));
    } on TimeoutException {
      fail(
        'no stop at line $line; errors: ${host.errors}; '
        'state: ${service.state}',
      );
    }
    return service.viewModel.focusedStackFrame!;
  }

  test('launches the program and stops at a breakpoint', () async {
    if (skip != false) return markTestSkipped('$skip');
    final source = _fixture('program.c');
    final line = markerLine(source, 'add');
    final d = await debug();
    await d.service.addBreakpoints(VsUri.file(source), [
      BreakpointData(lineNumber: line),
    ]);
    final ok = await d.service.startDebugging(
      d.service.configurationManager.getLaunches().first,
      {
        'type': lldbDapType,
        'request': 'launch',
        'name': 'Debug',
        'program': '${dir.path}/program',
        'cwd': dir.path,
      },
    );
    expect(ok, isTrue, reason: '${d.host.errors}');
    final frame = await stopAt(d.service, d.host, line);
    expect(frame.name, contains('add'));
    expect(await scopeValues(frame, 'Locals'), containsPair('a', '40'));
  });

  test('attaches to the process picked', () async {
    if (skip != false) return markTestSkipped('$skip');
    final source = _fixture('waiter.c');
    final line = markerLine(source, 'tick');
    final waiter = await Process.start('${dir.path}/waiter', const []);
    addTearDown(waiter.kill);
    // Nothing to read: it goes on to count.
    await waiter.stdin.close();

    final d = await debug();
    d.host.commands[pickProcessCommand] = (_) => '${waiter.pid}';
    await d.service.addBreakpoints(VsUri.file(source), [
      BreakpointData(lineNumber: line),
    ]);
    // The attach of the debugger's own initial configurations.
    final attach = d.service.registry
        .getDebugger(lldbDapType)!
        .contribution
        .list('initialConfigurations')!
        .cast<Json>()
        .singleWhere((config) => config['request'] == 'attach');
    final ok = await d.service.startDebugging(
      d.service.configurationManager.getLaunches().first,
      {...attach},
    );
    expect(ok, isTrue, reason: '${d.host.errors}');
    final session = d.service.model.getSessions().single;
    expect(session.configuration['pid'], waiter.pid);
    // Attached, it is stopped where it was: on its way, it meets the
    // breakpoint.
    try {
      await until(
        () => d.service.viewModel.focusedThread?.stopped ?? false,
        timeout: const Duration(seconds: 30),
      );
    } on TimeoutException {
      fail('not stopped once attached; errors: ${d.host.errors}');
    }
    if (d.service.viewModel.focusedStackFrame?.range.startLineNumber != line) {
      await d.service.viewModel.focusedThread!.continue_();
    }
    final frame = await stopAt(d.service, d.host, line);
    expect(frame.name, contains('tick'));
  });

  test('macOS: runs the program on a terminal of the IDE\'s', () async {
    if (skip != false) return markTestSkipped('$skip');
    if (!Platform.isMacOS) return markTestSkipped('macOS only');
    final source = _fixture('waiter.c');
    final line = markerLine(source, 'tick');
    // Never the user's own list of terminals' processes.
    PtyProcesses.registry = ChildProcessRegistry(
      file: File('${dir.path}/pty-processes.json'),
      lookup: (_) async => null,
      signal: (_) => false,
    );
    final terminals = TerminalService(root: dir.path);
    addTearDown(terminals.dispose);
    final d = await debug(
      openTerminal: ({title, cwd}) =>
          openDebugTerminal(terminals, title: title, cwd: cwd),
    );
    await d.service.addBreakpoints(VsUri.file(source), [
      BreakpointData(lineNumber: line),
    ]);
    final ok = await d.service.startDebugging(
      d.service.configurationManager.getLaunches().first,
      {
        'type': lldbDapType,
        'request': 'launch',
        'name': 'Debug in a terminal',
        'program': '${dir.path}/waiter',
        'cwd': dir.path,
        'runInTerminal': true,
      },
    );
    expect(ok, isTrue, reason: '${d.host.errors}');
    final session = d.service.model.getSessions().single;
    final terminal = terminals.instances.single;
    expect(session.configuration[debugTerminalKey], startsWith('/dev/'));
    expect(terminal.title, 'Debug in a terminal');

    // It waits for a word: typed in the terminal, the program reads it and
    // answers there, then goes on to the breakpoint.
    terminal.sendText('hello', shouldExecute: true);
    try {
      await until(
        () => _screen(terminal).contains('heard hello'),
        timeout: const Duration(seconds: 30),
      );
    } on TimeoutException {
      fail('the word was not answered; the terminal: ${_screen(terminal)}');
    }
    final frame = await stopAt(d.service, d.host, line);
    expect(frame.name, contains('tick'));

    // The session over, what kept the terminal open ends: the terminal
    // stays for what was printed, till a key is pressed.
    await d.service.stopSession(session);
    await until(
      () => terminal.waitingForKey,
      timeout: const Duration(seconds: 15),
    );
    expect(_screen(terminal), contains('heard hello'));
    // Nothing said of the stand-in that kept it open.
    expect(_screen(terminal), isNot(contains('/bin/sh')));
  });

  test('Linux: lldb-dap runs the program in a terminal itself', () async {
    if (skip != false) return markTestSkipped('$skip');
    // On macOS nothing may attach to Apple's own signed lldb-dap (Xcode's,
    // the command line tools'), which is what lldb-dap has the terminal
    // run: "Failed to attach to the target process".
    if (!Platform.isLinux) return markTestSkipped('Linux only');
    final source = _fixture('waiter.c');
    final line = markerLine(source, 'tick');
    final asked = <Json>[];
    Process? launched;
    addTearDown(() => launched?.kill());
    final d = await debug(
      runInTerminal: (args, sessionId) async {
        asked.add(args);
        // As the panel's terminal runs it: the first argument the
        // executable, the rest its arguments.
        final command = args.list('args')!.cast<String>();
        final process = launched = await Process.start(
          command.first,
          command.sublist(1),
          workingDirectory: args.str('cwd'),
        );
        await process.stdin.close();
        return process.pid;
      },
    );
    await d.service.addBreakpoints(VsUri.file(source), [
      BreakpointData(lineNumber: line),
    ]);
    final ok = await d.service.startDebugging(
      d.service.configurationManager.getLaunches().first,
      {
        'type': lldbDapType,
        'request': 'launch',
        'name': 'Debug in a terminal',
        'program': '${dir.path}/waiter',
        'cwd': dir.path,
        'runInTerminal': true,
      },
    );
    expect(ok, isTrue, reason: '${d.host.errors}');
    expect(asked, hasLength(1));
    final command = asked.single.list('args')!.cast<String>();
    expect(File(command.first).existsSync(), isTrue, reason: '$command');
    expect(command, contains('${dir.path}/waiter'));
    final frame = await stopAt(d.service, d.host, line);
    expect(frame.name, contains('tick'));
  });
}
