import 'dart:convert';
import 'dart:io';

import 'process_list.dart';

/// The processes as `ps` lists them.
abstract final class DebugProcesses {
  /// For BSD's `ps` (macOS) and procps's (Linux) alike:
  ///
  /// - `x`, BSD's option, first and without a dash: this user's processes,
  ///   those without a terminal too. (`-x` is no option of procps, and
  ///   POSIX's `-u <user>` needs a name.)
  /// - `-ww`: the command line however long, also when the app runs in a
  ///   terminal.
  /// - `-o <column>=` once per column: no header line. (One `-o` with
  ///   commas splits `pid=,etime=` differently by procps's personality.)
  static const arguments = [
    'x',
    '-ww',
    '-o',
    'pid=',
    '-o',
    'etime=',
    '-o',
    'args=',
  ];

  static Future<List<DebugProcess>> list() async {
    if (Platform.isWindows) return [];
    try {
      // Bytes: a command line is not always UTF-8, and one that is not
      // must not lose the list.
      final result = await Process.run(
        'ps',
        arguments,
        stdoutEncoding: null,
        stderrEncoding: null,
      );
      if (result.exitCode != 0) return [];
      final output = utf8.decode(
        result.stdout as List<int>,
        allowMalformed: true,
      );
      return [
        for (final process in parsePsOutput(
          output,
          isFile: FileSystemEntity.isFileSync,
        ))
          if (process.pid != pid && process.pid != result.pid) process,
      ]..sort(DebugProcess.mostRecentFirst);
    } on Object {
      // No `ps`, or one that will not run.
      return [];
    }
  }
}
