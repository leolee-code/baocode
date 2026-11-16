// A terminal of the panel's for a program a debugger starts itself. What
// runs in it is a stand-in: it says which device the terminal is (`tty`)
// and then only keeps it open, and the debugger gives that device to the
// program as its input, output and errors. lib/debug/adapters/lldb_dap.dart
// says why LLDB needs it on macOS.
//
// The program has the terminal to read and write, not as its controlling
// terminal: ^C there reaches the stand-in, not the program, and the
// program is not told of the window's size.

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../debug/adapters/native_debugger.dart';
import 'terminal/terminal_instance.dart' show TerminalLaunchConfig;
import 'terminal/terminal_service.dart';

/// What the stand-in is, for `sh -c`: its device's name written to the
/// file that is its `$0`, then a sleep that outlasts any session.
const debugTerminalScript =
    r'/usr/bin/tty > "$0" && exec /bin/sleep 2147483647';

/// A new terminal of [terminals], shown, for a program of a debugger's:
/// named [title], in [cwd]. Null when it did not say which device it is
/// within [timeout] (no `sh`, no `tty`: not macOS or Linux).
///
/// Closed, it stays in the panel for what the program printed, until a key
/// is pressed.
Future<DebugTerminal?> openDebugTerminal(
  TerminalService terminals, {
  String? title,
  String? cwd,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final Directory folder;
  try {
    folder = await Directory.systemTemp.createTemp('baocode-debug-tty-');
  } on FileSystemException {
    return null;
  }
  final told = File(p.join(folder.path, 'tty'));
  try {
    final instance = terminals.create(
      config: TerminalLaunchConfig(
        name: title,
        executable: '/bin/sh',
        arguments: ['-c', debugTerminalScript, told.path],
        cwd: cwd,
        waitOnExit: (_) => null,
      ),
    );
    terminals.show(instance);
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final tty = await _deviceIn(told);
      if (tty != null) {
        return DebugTerminal(tty: tty, close: () => instance.pty?.kill());
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    terminals.kill(instance);
    return null;
  } finally {
    try {
      await folder.delete(recursive: true);
    } on FileSystemException {
      // The system's to clear.
    }
  }
}

/// The device [told] names, once its line is whole.
Future<String?> _deviceIn(File told) async {
  try {
    final text = await told.readAsString();
    if (!text.endsWith('\n')) return null;
    final device = text.trim();
    return device.startsWith('/dev/') ? device : null;
  } on FileSystemException {
    // Not written yet.
    return null;
  }
}
