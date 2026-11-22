// Builds BaoCode Bash (third_party/bash-exe, github.com/baocode-dev/bash-exe):
// the bash.exe the Windows installer carries, which agents run their
// commands in there (lib/platform/windows_shell.dart). Run from anywhere in
// the repository:
//
//   dart run tool/build_bash_exe.dart               into build/bash/
//   dart run tool/build_bash_exe.dart --out <dir>   into <dir>
//   dart run tool/build_bash_exe.dart --arch arm64  on Windows: for which
//                                                   processor (x64 or arm64;
//                                                   this machine's when not
//                                                   given)
//
// On Windows it builds bash.exe for the --arch given; on macOS and Linux, a
// `bash` for this machine, to try the shell out while working on it (the app
// runs it on Windows only).
//
// It takes Rust's cargo from rustup, which installs the toolchain the source
// pins (third_party/bash-exe/rust-toolchain.toml) the first time; cargo then
// fetches the crates Cargo.lock names from crates.io. Both are downloads of
// the build, never of the app (docs/egress-policy.md). Cargo's own files go
// to build/bash-exe-target/.
//
// It writes the program and, under licenses/, the notices of the source it
// is built from: GPL-3.0-or-later for the whole, and the MIT and other
// notices of what it ports (see docs/bash-exe.md).
import 'dart:ffi' show Abi;
import 'dart:io';

/// The Rust target for each of the Windows installer's architectures.
const _windowsTargets = {
  'x64': 'x86_64-pc-windows-msvc',
  'arm64': 'aarch64-pc-windows-msvc',
};

Future<void> main(List<String> arguments) async {
  final root = File.fromUri(Platform.script).parent.parent.absolute;
  String? option(String name) {
    final at = arguments.indexOf(name);
    return at >= 0 && at + 1 < arguments.length ? arguments[at + 1] : null;
  }

  final source = Directory('${root.path}/third_party/bash-exe');
  if (!File('${source.path}/Cargo.toml').existsSync()) {
    _fail('No BaoCode Bash source at ${source.path}.');
  }
  final out = Directory(option('--out') ?? '${root.path}/build/bash')
    ..createSync(recursive: true);
  final targetDir = '${root.path}/build/bash-exe-target';

  final String? target;
  if (Platform.isWindows) {
    final arch =
        option('--arch') ??
        (Abi.current() == Abi.windowsArm64 ? 'arm64' : 'x64');
    target = _windowsTargets[arch];
    if (target == null) _fail('--arch is x64 or arm64, not $arch.');
  } else {
    if (option('--arch') != null) {
      _fail('--arch is for Windows; here it builds for this machine.');
    }
    target = null;
  }

  final cargo = _findCargo();
  _step(
    'Building BaoCode Bash'
    '${target == null ? ' for this machine' : ' ($target)'}',
  );
  await _run(cargo, [
    'build',
    '--release',
    '--locked',
    '-p',
    'bash-exe',
    '--target-dir',
    targetDir,
    if (target != null) ...['--target', target],
  ], source.path);

  final exe = Platform.isWindows ? 'bash.exe' : 'bash';
  final built = File(
    [targetDir, ?target, 'release', exe].join(Platform.pathSeparator),
  );
  if (!built.existsSync()) _fail('cargo left no ${built.path}.');
  final program = File('${out.path}/$exe');
  if (program.existsSync()) program.deleteSync();
  built.copySync(program.path);

  // The notices: the whole's GPL, and those of the crates that carry their
  // own (what is ported, and from where), at the paths they have in the
  // source.
  final licenses = Directory('${out.path}/licenses');
  if (licenses.existsSync()) licenses.deleteSync(recursive: true);
  for (final entry in source.listSync(recursive: true)) {
    if (entry is! File) continue;
    final relative = entry.path
        .substring(source.path.length + 1)
        .replaceAll(r'\', '/');
    if (relative.startsWith('target/') || relative.contains('/tests/')) {
      continue;
    }
    final name = relative.split('/').last;
    if (!RegExp(r'^(LICENSE|NOTICE)(-[A-Z]+)?$').hasMatch(name)) continue;
    final copy = File('${licenses.path}/$relative')
      ..parent.createSync(recursive: true);
    entry.copySync(copy.path);
  }

  _step('Done: ${program.path}');
}

/// rustup's cargo, which takes the toolchain rust-toolchain.toml pins: on
/// the PATH, else where rustup puts it.
String _findCargo() {
  final exe = Platform.isWindows ? 'cargo.exe' : 'cargo';
  final separator = Platform.isWindows ? ';' : ':';
  final path = Platform.environment['PATH'] ?? Platform.environment['Path'];
  for (final dir in (path ?? '').split(separator)) {
    if (dir.isEmpty) continue;
    final candidate = '$dir${Platform.pathSeparator}$exe';
    if (File(candidate).existsSync()) return candidate;
  }
  final home =
      Platform.environment['CARGO_HOME'] ??
      [
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'],
        '.cargo',
      ].join(Platform.pathSeparator);
  final installed = [home, 'bin', exe].join(Platform.pathSeparator);
  if (File(installed).existsSync()) return installed;
  _fail(
    'cargo (Rust) was not found. Install rustup, which installs the\n'
    'toolchain BaoCode Bash pins by itself:\n'
    '\n'
    '  winget install --id Rustlang.Rustup      (Windows)\n'
    '  https://rustup.rs                        (macOS, Linux)\n'
    '\n'
    'On Windows the Visual Studio C++ build tools Flutter builds with are\n'
    'also what cargo links with.',
  );
}

/// Runs [executable], its output shown as it comes (cargo's build takes
/// minutes); stops on a non-zero exit.
Future<void> _run(
  String executable,
  List<String> arguments,
  String workingDirectory,
) async {
  stdout.writeln('  \$ $executable ${arguments.join(' ')}');
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  if (code != 0) _fail('$executable exited with code $code.');
}

void _step(String message) => stdout.writeln('\n==> $message');

Never _fail(String message) {
  stderr.writeln('\n$message');
  exit(1);
}
