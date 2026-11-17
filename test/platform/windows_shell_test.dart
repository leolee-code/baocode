import 'package:bao_agent/bao_agent.dart' show Shell;
import 'package:baocode/platform/windows_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const _git = r'C:\Program Files\Git\bin\bash.exe';
const _cmd = r'C:\Windows\system32\cmd.exe';
const _pwsh = r'C:\Program Files\PowerShell\7\pwsh.exe';

class _Host implements WindowsShellHost {
  _Host({this.git});

  final String? git;

  @override
  String? gitBash() => git;

  @override
  String cmd() => _cmd;

  @override
  String powershell() => _pwsh;
}

class _Settings extends ChangeNotifier implements ShellSettings {
  final values = <String, Object?>{};

  @override
  Object? operator [](String key) => values[key];

  @override
  Future<void> update(String key, Object? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    notifyListeners();
  }
}

void main() {
  late _Settings settings;

  WindowsShells make({String? git = _git}) {
    settings = _Settings();
    return WindowsShells.current = WindowsShells(
      host: _Host(git: git),
      settings: settings,
    );
  }

  tearDown(() => WindowsShells.current = null);

  test('none picked: nothing changes, Git Bash shown as in use', () {
    final shells = make();
    expect(shells.chosen, isNull);
    expect(shells.inUse, (shell: WindowsShell.gitBash, executable: _git));
    expect(shells.shown, WindowsShell.gitBash);
    expect(WindowsShells.coreEnvironment(), isEmpty);
    expect(WindowsShells.cliEnvironment(), isEmpty);
  });

  test('none picked and no Git Bash: cmd', () {
    final shells = make(git: null);
    expect(shells.inUse, (shell: WindowsShell.cmd, executable: _cmd));
  });

  test('PowerShell picked: the built-in core runs it, the CLI keeps its '
      'own bash', () async {
    final shells = make();
    var told = 0;
    shells.addListener(() => told++);
    await shells.choose(WindowsShell.powershell);
    expect(settings.values[WindowsShell.settingKey], 'powershell');
    expect(told, greaterThan(0));
    expect(WindowsShells.coreEnvironment(), {Shell.chosenVariable: _pwsh});
    expect(WindowsShells.cliEnvironment(), isEmpty);
  });

  test('Git Bash picked: both cores run it', () async {
    final shells = make();
    await shells.choose(WindowsShell.gitBash);
    expect(WindowsShells.coreEnvironment(), {Shell.chosenVariable: _git});
    expect(WindowsShells.cliEnvironment(), {
      WindowsShells.cliBashVariable: _git,
    });
  });

  test('a custom one: the CLI is given it only when it is a bash', () async {
    final shells = make();
    await shells.choose(WindowsShell.custom);
    // No file named yet: as if none were picked.
    expect(shells.inUse.shell, WindowsShell.gitBash);
    expect(shells.shown, WindowsShell.custom);
    await shells.setCustomPath(r'  D:\msys\usr\bin\sh.exe ');
    expect(shells.customPath, r'D:\msys\usr\bin\sh.exe');
    expect(WindowsShells.cliEnvironment(), {
      WindowsShells.cliBashVariable: r'D:\msys\usr\bin\sh.exe',
    });
    await shells.setCustomPath(r'D:\tools\nu.exe');
    expect(WindowsShells.cliEnvironment(), isEmpty);
    expect(WindowsShells.coreEnvironment(), {
      Shell.chosenVariable: r'D:\tools\nu.exe',
    });
    await shells.setCustomPath('');
    expect(settings.values, isNot(contains(WindowsShell.pathKey)));
  });

  test('Git Bash picked but not installed: cmd in its place', () async {
    final shells = make(git: null);
    await shells.choose(WindowsShell.gitBash);
    expect(shells.inUse, (shell: WindowsShell.cmd, executable: _cmd));
    expect(WindowsShells.cliEnvironment(), isEmpty);
  });

  test('only bash files take bash', () {
    expect(WindowsShell.takesBash(WindowsShell.custom, r'C:\x\BASH.EXE'), true);
    expect(WindowsShell.takesBash(WindowsShell.custom, r'C:\x\zsh.exe'), false);
    expect(WindowsShell.takesBash(WindowsShell.cmd, _cmd), false);
    expect(WindowsShell.parse('powershell'), WindowsShell.powershell);
    expect(WindowsShell.parse('baoBash'), isNull);
  });
}
