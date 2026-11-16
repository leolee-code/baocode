import 'process_list_stub.dart'
    if (dart.library.io) 'process_list_io.dart'
    as platform;

/// A running process, as the attach picker lists it.
final class DebugProcess {
  const DebugProcess({
    required this.pid,
    required this.name,
    required this.command,
    this.elapsed,
  });

  final int pid;

  /// The executable's base name.
  final String name;

  /// The whole command line.
  final String command;

  /// How long it has run, when `ps` told.
  final Duration? elapsed;

  /// The picker's order: the most recently started first (those `ps` gave
  /// no age for last), and of two as old the higher pid, likely the later.
  static int mostRecentFirst(DebugProcess a, DebugProcess b) {
    final (first, second) = (a.elapsed, b.elapsed);
    if (first != second) {
      if (first == null) return 1;
      if (second == null) return -1;
      return first.compareTo(second);
    }
    return b.pid.compareTo(a.pid);
  }

  @override
  String toString() => 'DebugProcess($pid, $name, $elapsed, $command)';
}

/// `pid etime args`, the pid after any padding.
final _psLine = RegExp(r'^\s*(\d+)\s+(\S+)\s+(\S.*?)\s*$');

/// `[[dd-]hh:]mm:ss`.
final _elapsedTime = RegExp(r'^(?:(?:(\d+)-)?(\d+):)?(\d+):(\d+)$');

/// The processes in [output], `ps`'s with the columns pid, etime and args
/// (no headers). Lines that do not parse are skipped.
///
/// [isFile], whether a file is at a path, tells an executable whose path
/// has spaces from its arguments; without it the executable ends at the
/// first space.
List<DebugProcess> parsePsOutput(
  String output, {
  bool Function(String path)? isFile,
}) {
  final processes = <DebugProcess>[];
  for (final line in output.split('\n')) {
    final match = _psLine.firstMatch(line);
    if (match == null) continue;
    final pid = int.tryParse(match[1]!);
    if (pid == null) continue;
    final Duration? elapsed;
    // A `-` is an age `ps` could not tell.
    if (match[2] == '-') {
      elapsed = null;
    } else {
      elapsed = _parseElapsed(match[2]!);
      if (elapsed == null) continue;
    }
    final command = match[3]!;
    processes.add(
      DebugProcess(
        pid: pid,
        name: _executableName(command, isFile),
        command: command,
        elapsed: elapsed,
      ),
    );
  }
  return processes;
}

Duration? _parseElapsed(String etime) {
  final match = _elapsedTime.firstMatch(etime);
  if (match == null) return null;
  final [days, hours, minutes, seconds] = [
    for (var group = 1; group <= 4; group++)
      match[group] == null ? 0 : int.tryParse(match[group]!),
  ];
  if (days == null || hours == null || minutes == null || seconds == null) {
    return null;
  }
  return Duration(days: days, hours: hours, minutes: minutes, seconds: seconds);
}

/// The base name of the executable [command] runs.
///
/// `args` is the arguments joined by spaces, so where the executable's
/// path ends is not in it: `/Applications/Some App.app/Contents/MacOS/Some
/// App --flag` reads like `/bin/cat /etc/hosts`. (`comm` would be the
/// executable alone, but it has spaces too, so it cannot be a column
/// before `args`; and Linux cuts it to 15 characters.) So:
///
/// - An absolute path, with [isFile]: the shortest stretch up to a space
///   (or the end) that is a file. The shortest, as an interpreter's script
///   is a file as well.
/// - Otherwise, and when no stretch is a file (the executable was removed,
///   or lives in a container's filesystem): up to the first space, without
///   the `-` a login shell is started with (`-zsh`) and the `:` of a
///   title a daemon gave itself (`nginx: worker process`).
/// - What `ps` shows in brackets for a process without arguments
///   (`[kworker/0:1]`, `(bash)`), or as `<defunct>`: as it is.
String _executableName(String command, bool Function(String path)? isFile) {
  if (isFile != null && command.startsWith('/')) {
    var end = command.indexOf(' ');
    while (true) {
      final path = end < 0 ? command : command.substring(0, end);
      if (isFile(path)) return _baseName(path);
      if (end < 0) break;
      end = command.indexOf(' ', end + 1);
    }
  }
  final space = command.indexOf(' ');
  var word = space < 0 ? command : command.substring(0, space);
  if (word.startsWith(RegExp(r'[\[(<]'))) return word;
  if (word.startsWith('-') && word.length > 1) word = word.substring(1);
  if (word.endsWith(':') && word.length > 1) {
    word = word.substring(0, word.length - 1);
  }
  return _baseName(word);
}

String _baseName(String path) {
  final name = path.substring(path.lastIndexOf('/') + 1);
  return name.isEmpty ? path : name;
}

/// This user's running processes, the most recently started first, without
/// this app's own process and the `ps` that listed them. Empty where there
/// is no `ps` (the web, Windows).
Future<List<DebugProcess>> listDebugProcesses() =>
    platform.DebugProcesses.list();
