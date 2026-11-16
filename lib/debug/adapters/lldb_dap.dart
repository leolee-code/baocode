// LLDB, through LLVM's own adapter (lldb-dap; `lldb-vscode` before LLVM
// 18): the one this machine has (Xcode's or its command line tools' on
// macOS, the distribution's package on Linux), spoken to over its stdio.
// For C and C++.
//
// The debug type and its launch.json attributes are those of LLVM's VS
// Code extension (llvm-vs-code-extensions.lldb-dap), so a launch.json
// written for it runs here as it is.
//
// A program run in a terminal (`"runInTerminal": true`, or `"console":
// "integratedTerminal"`): lldb-dap has the client start a copy of
// lldb-dap in a terminal (DAP's `runInTerminal`), attaches to it, and has
// it become the program. On macOS nothing may attach to a program Apple
// signed, as Xcode's and the command line tools' lldb-dap are, so that
// fails there ("Failed to attach to the target process"). There LLDB
// starts the program itself, with a terminal of the IDE's as its input,
// output and errors (`target.input-path` and the like): see
// [LldbDapDebugger.resolve].

import 'dart:async';

import '../../kernel/claude_code/claude_environment.dart';
import '../common/debug_types.dart';
import '../common/debug_utils.dart' show DebugTargetOs;
import '../service/debug_host.dart';
import '../service/debugger.dart';
import '../session/debug_adapter.dart';
import '../session/debug_session.dart';
import '../session/stream_debug_adapter.dart';
import '../ui/debug_strings.dart';
import 'lldb_dap_locator.dart';
import 'native_debugger.dart';

/// launch.json's `type` for LLDB.
const lldbDapType = 'lldb-dap';

/// settings.json's path to lldb-dap, for one not found, or another than
/// the one found.
const lldbDapPathSetting = 'debug.lldbDap.path';

/// The command `${command:pickProcess}` runs: a process picked, its id.
const pickProcessCommand = 'baocode.debug.pickProcess';

/// The languages LLDB debugs here (the catalog's ids).
const _languages = ['c', 'cpp'];

/// LLDB (see the top of the file). [locate] finds lldb-dap, and
/// [environment] is what it runs in: the login shell's, as a terminal's
/// programs have it.
final class LldbDapDebugger extends NativeDebugger {
  const LldbDapDebugger({this.locate = locateLldbDap, this.environment});

  final Future<String?> Function({String? configured}) locate;
  final Future<Map<String, String>> Function()? environment;

  @override
  String get type => lldbDapType;

  @override
  DebuggerExtension get extension => const DebuggerExtension(
    id: 'baocode.lldb-dap',
    isBuiltin: true,
    debuggers: [
      {
        'type': lldbDapType,
        'label': 'LLDB',
        'languages': _languages,
        'variables': {'pickProcess': pickProcessCommand},
        'initialConfigurations': [
          {
            'type': lldbDapType,
            'request': 'launch',
            'name': 'Debug',
            'program': r'${workspaceFolder}/<your program>',
            'args': <String>[],
            'cwd': r'${workspaceFolder}',
          },
          {
            'type': lldbDapType,
            'request': 'attach',
            'name': 'Attach to Process',
            'pid': r'${command:pickProcess}',
          },
        ],
      },
    ],
    breakpoints: [
      {'language': 'c'},
      {'language': 'cpp'},
    ],
  );

  @override
  Future<DebugAdapterTransport> open(
    DebugSession session,
    DebugServiceHost host,
  ) async {
    final configured = switch (host.configurationValue(lldbDapPathSetting)) {
      final String path when path.trim().isNotEmpty => path.trim(),
      _ => null,
    };
    final path = await locate(configured: configured);
    if (path == null) {
      final strings = DebugStrings.forLanguage(host.locale);
      throw DebugAdapterUnavailable(
        configured != null
            ? strings.lldbDapPathMissing(configured)
            : host.targetOs == DebugTargetOs.macintosh
            ? strings.lldbDapMissingMac
            : strings.lldbDapMissingLinux,
      );
    }
    return StdioDebugAdapterTransport(
      path,
      const [],
      workingDirectory: session.root?.uri.fsPath(windows: host.isWindows),
      environment: await (environment ?? ClaudeEnvironment.of)(),
    );
  }

  /// `pid` as a number: `${command:pickProcess}` leaves it as text, which
  /// lldb-dap does not take. On macOS, a launch in a terminal as LLDB can
  /// do it there (see the top of the file): [openTerminal]'s device for
  /// the program's input, output and errors, set before the user's own
  /// `initCommands`, and lldb-dap not asked for a terminal. Without a
  /// terminal to open, the configuration stays as it is written.
  @override
  Future<Json> resolve(
    Json config,
    DebugServiceHost host, {
    OpenDebugTerminal? openTerminal,
  }) async {
    final resolved = switch (config['pid']) {
      final String pid when int.tryParse(pid.trim()) != null => {
        ...config,
        'pid': int.parse(pid.trim()),
      },
      _ => config,
    };
    if (openTerminal == null ||
        host.targetOs != DebugTargetOs.macintosh ||
        resolved['request'] != 'launch' ||
        !(resolved['runInTerminal'] == true ||
            resolved['console'] == 'integratedTerminal')) {
      return resolved;
    }
    final terminal = await openTerminal(
      title: resolved.str('name'),
      cwd: resolved.str('cwd'),
    );
    if (terminal == null) return resolved;
    return {
      ...resolved,
      'runInTerminal': false,
      if (resolved.containsKey('console')) 'console': 'internalConsole',
      'initCommands': [
        for (final stream in const ['input', 'output', 'error'])
          'settings set target.$stream-path ${terminal.tty}',
        ...?resolved.list('initCommands'),
      ],
      debugTerminalKey: terminal.tty,
    };
  }
}
