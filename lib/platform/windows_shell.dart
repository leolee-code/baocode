import 'dart:async';

import 'package:bao_agent/bao_agent.dart' show Shell;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'windows_shell_stub.dart'
    if (dart.library.io) 'windows_shell_io.dart'
    as platform;

/// Settings → General → Command Line (Windows): what agents run their
/// commands in (`commandLine.shell` in settings.json; [custom] the file
/// `commandLine.shellPath` names).
enum WindowsShell {
  /// BaoCode Bash, which the installer carries (`bash\bash.exe` beside the
  /// app, built from third_party/bash-exe): bash with `rg`, `sed`, `jq` and
  /// the other usual tools built in. Named as upstream's settings name it.
  baoBash,

  /// Git for Windows' bash, where it is installed.
  gitBash,
  cmd,
  powershell,
  custom;

  static const settingKey = 'commandLine.shell';
  static const pathKey = 'commandLine.shellPath';

  /// The pick a setting's [value] names; null for none.
  static WindowsShell? parse(Object? value) =>
      values.where((shell) => shell.name == value).firstOrNull;

  /// Whether it takes bash's commands, as Claude Code's CLI needs: a custom
  /// one when its file is a `bash.exe` or `sh.exe`.
  static bool takesBash(WindowsShell shell, String executable) =>
      switch (shell) {
        baoBash || gitBash => true,
        cmd || powershell => false,
        custom => RegExp(
          r'(^|[\\/])(bash|sh)(\.exe)?$',
          caseSensitive: false,
        ).hasMatch(executable),
      };
}

/// The shell agents run commands in now, and its file.
typedef WindowsShellInUse = ({WindowsShell shell, String executable});

/// Where the pick is kept: settings.json (app_settings.dart), told as it
/// changes.
abstract interface class ShellSettings implements Listenable {
  Object? operator [](String key);

  Future<void> update(String key, Object? value);
}

/// Where BaoCode Bash may be, first found first: beside [executable] as the
/// installer puts it (`bash\bash.exe`, tool/build_windows.dart), then, for a
/// development run, `build\bash\` of the checkout (the working folder's, or
/// one the executable is built under) as tool/build_bash_exe.dart leaves it.
List<String> baoBashCandidates({
  required String executable,
  required String current,
}) {
  final windows = p.windows;
  final exeDir = windows.dirname(executable);
  return [
    windows.join(exeDir, 'bash', 'bash.exe'),
    windows.join(current, 'build', 'bash', 'bash.exe'),
    // A debug build's executable is under the checkout's build\.
    for (var dir = exeDir, i = 0; i < 10; dir = windows.dirname(dir), i++)
      if (windows.basename(dir) == 'build')
        windows.join(dir, 'bash', 'bash.exe'),
  ];
}

/// Finds the shells to pick from on this machine (windows_shell_io.dart);
/// replaceable under test.
abstract interface class WindowsShellHost {
  /// BaoCode Bash's `bash.exe` ([baoBashCandidates]); null where this
  /// build carries none.
  String? baoBash();

  /// Git for Windows' `bash.exe`; null where it is not installed.
  String? gitBash();

  /// cmd.exe.
  String cmd();

  /// PowerShell 7's `pwsh.exe` where it is installed, else Windows
  /// PowerShell's `powershell.exe`.
  String powershell();
}

/// The pick of the shell agents run commands in, on Windows. Picked, both
/// cores run their commands in it: the built-in one ([coreEnvironment];
/// `Shell.find` in bao_agent), Claude Code's CLI ([cliEnvironment]) where
/// it takes bash. With none picked: a `CLAUDE_CODE_GIT_BASH_PATH` the user
/// set, else BaoCode Bash where the app carries it, else Git Bash, else
/// cmd.exe.
///
/// Nothing is downloaded: BaoCode Bash comes with the installer, built from
/// source (docs/bash-exe.md); the other shells are the machine's own.
class WindowsShells extends ChangeNotifier {
  WindowsShells({required this.host, this.settings}) {
    settings?.addListener(notifyListeners);
  }

  /// The app's, made in main(); null where it is not offered: anywhere
  /// but Windows, and under test.
  static WindowsShells? current;

  /// The platform's, with the pick kept in [settings]; null where it is
  /// not offered.
  static WindowsShells? forPlatform({ShellSettings? settings}) {
    final host = platform.windowsShellHost();
    if (host == null) return null;
    return WindowsShells(host: host, settings: settings);
  }

  /// What the built-in core's environment gets: BaoCode Bash where the app
  /// carries it (`BAOCODE_BASH`, which `Shell.find` takes after a bash the
  /// user set, and tells the model of), and the shell picked
  /// (`BAOCODE_SHELL`). Nothing where it is not offered.
  static Map<String, String> coreEnvironment() {
    final shells = current;
    if (shells == null) return const {};
    return {
      Shell.baoBashVariable: ?shells.baoBash,
      if (shells.chosen != null) Shell.chosenVariable: shells.inUse.executable,
    };
  }

  /// The variable Claude Code's CLI takes the bash its Bash tool runs from
  /// (on Windows; a file called `bash.exe` or `sh.exe`, else it goes back
  /// to Git Bash).
  static const cliBashVariable = 'CLAUDE_CODE_GIT_BASH_PATH';

  /// What the CLI's environment gets, for it to run commands in the shell
  /// picked where that takes bash (else it finds Git Bash itself):
  /// [cliBashVariable], ahead of one the user set. With none picked,
  /// BaoCode Bash where the app carries it, unless [environment] (the
  /// CLI's own) names a bash already: theirs stays, as does one in their
  /// settings.json's `env`, which the CLI reads after.
  static Map<String, String> cliEnvironment([
    Map<String, String> environment = const {},
  ]) {
    final shells = current;
    if (shells == null) return const {};
    if (shells.chosen == null) {
      final bash = shells.baoBash;
      final theirs = environment[cliBashVariable];
      if (bash == null || (theirs != null && theirs.isNotEmpty)) {
        return const {};
      }
      return {cliBashVariable: bash};
    }
    final (:shell, :executable) = shells.inUse;
    if (!WindowsShell.takesBash(shell, executable)) return const {};
    return {cliBashVariable: executable};
  }

  /// Whether [cliEnvironment]'s [given] has the CLI run BaoCode Bash, which
  /// it is then told of ([Shell.baoBashNote]).
  static bool cliRunsBaoBash(Map<String, String> given) {
    final bash = current?.baoBash;
    return bash != null && given[cliBashVariable] == bash;
  }

  final WindowsShellHost host;

  /// Where the pick is kept; none under test.
  final ShellSettings? settings;

  @override
  void dispose() {
    settings?.removeListener(notifyListeners);
    super.dispose();
  }

  /// The shell picked in Settings; null for none.
  WindowsShell? get chosen =>
      WindowsShell.parse(settings?[WindowsShell.settingKey]);

  /// The file a [WindowsShell.custom] pick runs; null for none.
  String? get customPath => switch (settings?[WindowsShell.pathKey]) {
    final String path when path.trim().isNotEmpty => path.trim(),
    _ => null,
  };

  /// BaoCode Bash, as looked for once.
  late final String? baoBash = host.baoBash();

  /// Git Bash, as looked for once.
  late final String? gitBash = host.gitBash();

  /// The shell agents run commands in: the one picked, where it can run
  /// (BaoCode Bash or Git Bash found, a custom file named); else, as with
  /// none picked, BaoCode Bash where the app carries it, else Git Bash where
  /// installed, else cmd.exe.
  WindowsShellInUse get inUse {
    final picked = switch (chosen) {
      WindowsShell.baoBash => baoBash,
      WindowsShell.gitBash => gitBash,
      WindowsShell.cmd => host.cmd(),
      WindowsShell.powershell => host.powershell(),
      WindowsShell.custom => customPath,
      null => null,
    };
    if ((chosen, picked) case (final shell?, final executable?)) {
      return (shell: shell, executable: executable);
    }
    if (baoBash case final bash?) {
      return (shell: WindowsShell.baoBash, executable: bash);
    }
    if (gitBash case final git?) {
      return (shell: WindowsShell.gitBash, executable: git);
    }
    return (shell: WindowsShell.cmd, executable: host.cmd());
  }

  /// What Settings shows picked: the pick, else the shell in use.
  WindowsShell get shown => chosen ?? inUse.shell;

  /// Picks [shell].
  Future<void> choose(WindowsShell shell) async {
    try {
      await settings?.update(WindowsShell.settingKey, shell.name);
    } on Object catch (error) {
      // A settings file that does not parse is left as it is; its error
      // is shown.
      debugPrint('${WindowsShell.settingKey} not kept: $error');
    }
    notifyListeners();
  }

  /// Sets the file a [WindowsShell.custom] pick runs.
  Future<void> setCustomPath(String path) async {
    try {
      await settings?.update(
        WindowsShell.pathKey,
        path.trim().isEmpty ? null : path.trim(),
      );
    } on Object catch (error) {
      debugPrint('${WindowsShell.pathKey} not kept: $error');
    }
  }
}
