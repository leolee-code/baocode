import 'lldb_dap_locator_stub.dart'
    if (dart.library.io) 'lldb_dap_locator_io.dart'
    as platform;

/// Where this machine's lldb-dap is; null when there is none.
/// [configured] is settings.json's `debug.lldbDap.path`: when it is set
/// (non-empty), only it is tried — it is returned if that file exists, else
/// null (no fallback), so the caller can say the setting points nowhere.
Future<String?> locateLldbDap({String? configured}) =>
    platform.LldbDapLocator.locate(configured: configured);

/// The search for lldb-dap, over a machine given as its parts.
final class LldbDapSearch {
  const LldbDapSearch({
    required this.environment,
    required this.isMacOS,
    required this.exists,
    required this.list,
    required this.xcrun,
  });

  /// The login shell's: `LLDB_DAP`, `PATH` and `HOME` are read.
  final Map<String, String> environment;

  final bool isMacOS;

  /// Whether a file is at [path].
  final bool Function(String path) exists;

  /// The names in [directory]; none when it is unreadable.
  final List<String> Function(String directory) list;

  /// Where Xcode's [tool] is (`xcrun -f`); null when it has none, or there
  /// is no Xcode.
  final Future<String?> Function(String tool) xcrun;

  /// Where Xcode, its command line tools and Homebrew's LLVM (Apple
  /// silicon, Intel) keep theirs.
  static const macFallbacks = [
    '/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-dap',
    '/Library/Developer/CommandLineTools/usr/bin/lldb-dap',
    '/opt/homebrew/opt/llvm/bin/lldb-dap',
    '/usr/local/opt/llvm/bin/lldb-dap',
  ];

  /// The first there is of: [configured] (alone, when set); `$LLDB_DAP`;
  /// Xcode's (macOS); `lldb-dap` on the PATH, then `lldb-vscode`, its name
  /// before LLVM 18; [macFallbacks] (macOS).
  Future<String?> find({String? configured}) async {
    final setting = configured?.trim() ?? '';
    if (setting.isNotEmpty) return _existing(_expandHome(setting));

    final named = _existing(environment['LLDB_DAP']);
    if (named != null) return named;

    if (isMacOS) {
      final xcode = _existing((await xcrun('lldb-dap'))?.trim());
      if (xcode != null) return xcode;
    }

    final directories = _pathDirectories();
    final listings = <String, List<String>>{};
    for (final name in const ['lldb-dap', 'lldb-vscode']) {
      for (final directory in directories) {
        final found =
            _existing(_join(directory, name)) ??
            _highestVersion(
              directory,
              name,
              listings[directory] ??= list(directory),
            );
        if (found != null) return found;
      }
    }

    if (isMacOS) {
      for (final path in macFallbacks) {
        if (exists(path)) return path;
      }
    }
    return null;
  }

  String? _existing(String? path) =>
      path != null && path.isNotEmpty && exists(path) ? path : null;

  /// [path] with a leading `~/` as the home folder.
  String _expandHome(String path) {
    final home = environment['HOME'] ?? '';
    if (home.isEmpty || !path.startsWith('~/')) return path;
    return _join(home, path.substring(2));
  }

  /// The PATH's folders in order. Only absolute ones: an empty or relative
  /// entry means the working directory, which is not where the user keeps
  /// a debugger.
  List<String> _pathDirectories() => [
    for (final entry in (environment['PATH'] ?? '').split(':'))
      if (entry.startsWith('/')) entry,
  ];

  /// The `<name>-<N>` of the highest N among [names] (Debian's and Ubuntu's
  /// naming: `lldb-dap-18`) that is a file in [directory].
  String? _highestVersion(String directory, String name, List<String> names) {
    final versioned = RegExp('^${RegExp.escape(name)}-(\\d+)\$');
    final versions = <(int, String)>[
      for (final entry in names)
        if (versioned.firstMatch(entry)?[1] case final digits?)
          if (int.tryParse(digits) case final version?) (version, entry),
    ]..sort((a, b) => b.$1.compareTo(a.$1));
    for (final (_, entry) in versions) {
      final path = _existing(_join(directory, entry));
      if (path != null) return path;
    }
    return null;
  }

  static String _join(String directory, String name) =>
      directory.endsWith('/') ? '$directory$name' : '$directory/$name';
}
