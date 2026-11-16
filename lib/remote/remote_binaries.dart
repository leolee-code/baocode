import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bao_remote/client.dart';
import 'package:bao_remote/local.dart' show ClaudeEnvironment;
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import 'host_server_platform.dart'
    if (dart.library.ffi) 'host_server_platform_ffi.dart';

/// The server builds in [directory] (tool/build_remote_server.dart writes
/// them): `baocode-server-<platform>` (`linux-x64`, `darwin-arm64`, …), and
/// `VERSION`, which names them.
class DirectoryServerBinaries implements RemoteServerBinaries {
  DirectoryServerBinaries(this.directory, this.version);

  /// Those in [directory], if it has a `VERSION` and a build.
  static DirectoryServerBinaries? at(String directory) {
    final version = readVersion(directory);
    if (version == null) return null;
    final built = platforms.any(
      (platform) => File(p.join(directory, fileName(platform))).existsSync(),
    );
    return built ? DirectoryServerBinaries(directory, version) : null;
  }

  /// [directory]'s `VERSION`; null when it has none, or not one that can
  /// name a folder.
  static String? readVersion(String directory) {
    final file = File(p.join(directory, 'VERSION'));
    if (!file.existsSync()) return null;
    final version = file.readAsStringSync().trim();
    if (version.isEmpty || version.contains(RegExp(r'[^A-Za-z0-9._+-]'))) {
      return null;
    }
    return version;
  }

  final String directory;

  @override
  final String version;

  static String fileName(String platform) => 'baocode-server-$platform';

  /// Those there are builds for.
  static const platforms = [
    'linux-x64',
    'linux-arm64',
    'linux-riscv64',
    'darwin-x64',
    'darwin-arm64',
    'windows-x64',
    'windows-arm64',
  ];

  @override
  Future<List<int>?> read(String platform) async {
    final file = File(p.join(directory, fileName(platform)));
    return file.existsSync() ? file.readAsBytes() : null;
  }
}

/// The server builds the app carries (never downloaded): in the bundle's
/// resources on macOS
/// (`Contents/Resources/remote`), beside the executable elsewhere
/// (`remote/`); `BAOCODE_REMOTE_SERVER_DIR`, else `build/remote` of the
/// checkout (the working folder's, or one the executable is built under),
/// in development. Null when there are none.
RemoteServerBinaries? bundledServerBinaries({
  Map<String, String>? environment,
  String? executable,
  String? current,
}) {
  environment ??= Platform.environment;
  executable ??= Platform.resolvedExecutable;
  current ??= Directory.current.path;
  final exeDir = p.dirname(executable);
  final directories = [
    ?environment['BAOCODE_REMOTE_SERVER_DIR'],
    if (Platform.isMacOS) p.join(p.dirname(exeDir), 'Resources', 'remote'),
    p.join(exeDir, 'remote'),
    p.join(exeDir, 'data', 'remote'),
    p.join(current, 'build', 'remote'),
    // A debug build's executable is under the checkout's build/.
    for (var dir = exeDir, i = 0; i < 10; dir = p.dirname(dir), i++)
      if (p.basename(dir) == 'build') p.join(dir, 'remote'),
  ];
  for (final directory in directories) {
    if (DirectoryServerBinaries.at(directory) case final found?) return found;
  }
  return null;
}

/// The server built from the checkout's sources as a host needs it: for a
/// development run of the app, which carries no build. Named by its
/// sources, so that a host is given it anew once they change.
class SourceServerBinaries implements RemoteServerBinaries {
  SourceServerBinaries._(
    this.root,
    this.version,
    this._dart,
    this._environment,
  );

  /// The checkout the app runs from: the working folder's, or one the
  /// executable is built under; null for none (an installed app).
  static Future<SourceServerBinaries?> find({
    String? current,
    String? executable,
    Map<String, String>? environment,
  }) async {
    current ??= Directory.current.path;
    executable ??= Platform.resolvedExecutable;
    String? root;
    for (final start in [current, p.dirname(executable)]) {
      for (var dir = start, i = 0; i < 12; dir = p.dirname(dir), i++) {
        if (File(p.join(dir, _source)).existsSync()) {
          root = dir;
          break;
        }
        if (p.dirname(dir) == dir) break;
      }
      if (root != null) break;
    }
    if (root == null) return null;
    // The login shell's, as the user's terminal has it: an app started
    // from the Dock has little of a PATH.
    environment ??= await ClaudeEnvironment.of();
    final dart = _findDart(environment);
    if (dart == null) return null;
    return SourceServerBinaries._(
      root,
      'dev-${_hashSources(root)}',
      dart,
      environment,
    );
  }

  static const _source = 'packages/bao_remote/bin/baocode_server.dart';

  /// The packages the server is built from.
  static const _serverPackages = ['bao_remote', 'bao_agent'];

  final String root;
  final String _dart;
  final Map<String, String> _environment;

  @override
  final String version;

  final Map<String, Future<List<int>?>> _built = {};

  @override
  Future<List<int>?> read(String platform) =>
      _built[platform] ??= _build(platform);

  /// Linux builds are cross-compiled; a macOS one only on a Mac of its
  /// architecture, a Windows one only on Windows of its, as `dart compile
  /// exe` builds for them.
  Future<List<int>?> _build(String platform) async {
    final [os, arch] = platform.split('-');
    final name = SshLauncher.describe(platform);
    final host = hostServerPlatform();
    if (os != 'linux' && platform != host) {
      throw SshConnectException(
        SshFailure.server,
        'The BaoCode server for $name can only be built on '
        '${os == 'darwin' ? 'a Mac' : 'Windows'} of that architecture: run '
        'tool/build_remote_server.dart there (--only $platform), and give '
        'its build to this one with --from',
      );
    }
    final out = File(
      p.join(root, 'build', 'remote', 'dev', '$version-$platform'),
    );
    if (!out.existsSync()) {
      out.parent.createSync(recursive: true);
      final result = await Process.run(
        _dart,
        [
          'compile',
          'exe',
          '--target-os',
          os == 'darwin' ? 'macos' : os,
          '--target-arch',
          arch,
          '-Dbaocode.version=$version',
          '-o',
          out.path,
          _source,
        ],
        workingDirectory: root,
        environment: _environment,
      );
      if (result.exitCode != 0) {
        _built.remove(platform);
        throw SshConnectException(
          SshFailure.server,
          'The BaoCode server could not be built for $name',
          detail: '${result.stdout}\n${result.stderr}'.trim(),
        );
      }
    }
    return out.readAsBytes();
  }

  /// `dart`: Flutter's, else the PATH's.
  static String? _findDart(Map<String, String> environment) {
    final separator = Platform.isWindows ? ';' : ':';
    final name = Platform.isWindows ? 'dart.exe' : 'dart';
    for (final candidate in [
      if (environment['FLUTTER_ROOT'] case final flutter?)
        p.join(flutter, 'bin', name),
      for (final dir in (environment['PATH'] ?? '').split(separator))
        if (dir.isNotEmpty) p.join(dir, name),
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// The server's sources, hashed: its package's Dart and pubspec, and
  /// those of the core it carries (package:bao_agent).
  static String _hashSources(String root) {
    final packages = Directory(p.join(root, 'packages'));
    final files = [
      for (final name in _serverPackages)
        if (Directory(p.join(packages.path, name)) case final dir
            when dir.existsSync())
          for (final entry in dir.listSync(recursive: true))
            if (entry is File &&
                (entry.path.endsWith('.dart') ||
                    p.basename(entry.path) == 'pubspec.yaml') &&
                !p
                    .split(p.relative(entry.path, from: packages.path))
                    .any((part) => part == '.dart_tool' || part == 'test'))
              entry,
    ]..sort((a, b) => a.path.compareTo(b.path));
    final bytes = BytesBuilder(copy: false);
    for (final file in files) {
      bytes
        ..add(utf8.encode(p.relative(file.path, from: packages.path)))
        ..add(file.readAsBytesSync());
    }
    return '${crypto.sha256.convert(bytes.takeBytes())}'.substring(0, 12);
  }
}
