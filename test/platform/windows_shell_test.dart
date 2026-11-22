import 'package:bao_agent/bao_agent.dart' show Shell;
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/process_transport_io.dart';
import 'package:baocode/platform/windows_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const _bao = r'C:\Program Files\BaoCode\bash\bash.exe';
const _git = r'C:\Program Files\Git\bin\bash.exe';
const _cmd = r'C:\Windows\system32\cmd.exe';
const _pwsh = r'C:\Program Files\PowerShell\7\pwsh.exe';

class _Host implements WindowsShellHost {
  _Host({this.git, this.bao});

  final String? git;
  final String? bao;

  @override
  String? baoBash() => bao;

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

  WindowsShells make({String? git = _git, String? bao}) {
    settings = _Settings();
    return WindowsShells.current = WindowsShells(
      host: _Host(git: git, bao: bao),
      settings: settings,
    );
  }

  /// The shell the built-in core finds in [environment] where every file
  /// is there.
  Shell coreShell(Map<String, String> environment) =>
      Shell.find(environment, windows: true, exists: (_) => true);

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
    expect(WindowsShell.takesBash(WindowsShell.baoBash, _bao), true);
    // As upstream's settings name it.
    expect(WindowsShell.parse('baoBash'), WindowsShell.baoBash);
  });

  test('BaoCode Bash carried, none picked: both cores run it, ahead of Git '
      'Bash, and the CLI is told what it has', () {
    final shells = make(bao: _bao);
    expect(shells.inUse, (shell: WindowsShell.baoBash, executable: _bao));
    expect(shells.shown, WindowsShell.baoBash);
    final core = WindowsShells.coreEnvironment();
    expect(core, {Shell.baoBashVariable: _bao});
    final found = coreShell(core);
    expect((found.executable, found.baoBash), (_bao, true));
    final cli = WindowsShells.cliEnvironment();
    expect(cli, {WindowsShells.cliBashVariable: _bao});
    expect(WindowsShells.cliRunsBaoBash(cli), isTrue);

    const launch = ClaudeLaunch(cwd: '/p', instructions: 'Be brief.');
    final told = ProcessTransport.toldOfBash(launch, cli);
    expect(told.instructions, '${Shell.baoBashNote}\n\nBe brief.');
    // Not where the launch's instructions are all its prompt.
    const own = ClaudeLaunch(cwd: '/p', instructions: 'Mine.', ownPrompt: true);
    expect(ProcessTransport.toldOfBash(own, cli).instructions, 'Mine.');
  });

  test('a bash the user named for the CLI stays theirs', () {
    make(bao: _bao);
    const theirs = r'D:\msys\usr\bin\bash.exe';
    final cli = WindowsShells.cliEnvironment({
      WindowsShells.cliBashVariable: theirs,
    });
    expect(cli, isEmpty);
    const launch = ClaudeLaunch(cwd: '/p');
    expect(ProcessTransport.toldOfBash(launch, cli).instructions, isNull);
    // The built-in core takes theirs ahead of BaoCode Bash too.
    final found = coreShell({
      ...WindowsShells.coreEnvironment(),
      WindowsShells.cliBashVariable: theirs,
    });
    expect((found.executable, found.baoBash), (theirs, false));
  });

  test('cmd picked: the built-in core runs cmd, the CLI is not given '
      'BaoCode Bash', () async {
    final shells = make(bao: _bao);
    await shells.choose(WindowsShell.cmd);
    expect(WindowsShells.coreEnvironment(), {
      Shell.baoBashVariable: _bao,
      Shell.chosenVariable: _cmd,
    });
    expect(coreShell(WindowsShells.coreEnvironment()).posix, isFalse);
    expect(WindowsShells.cliEnvironment(), isEmpty);
  });

  test('BaoCode Bash picked: both cores run it, told as such', () async {
    final shells = make(bao: _bao);
    await shells.choose(WindowsShell.baoBash);
    expect(settings.values[WindowsShell.settingKey], 'baoBash');
    final found = coreShell(WindowsShells.coreEnvironment());
    expect((found.executable, found.baoBash), (_bao, true));
    final cli = WindowsShells.cliEnvironment();
    expect(cli, {WindowsShells.cliBashVariable: _bao});
    expect(WindowsShells.cliRunsBaoBash(cli), isTrue);
  });

  test('BaoCode Bash picked but not carried: Git Bash in its place', () async {
    final shells = make();
    await shells.choose(WindowsShell.baoBash);
    expect(shells.inUse, (shell: WindowsShell.gitBash, executable: _git));
    expect(WindowsShells.coreEnvironment(), {Shell.chosenVariable: _git});
    expect(WindowsShells.cliRunsBaoBash(WindowsShells.cliEnvironment()), false);
  });

  test('BaoCode Bash is looked for beside the app, then in a checkout', () {
    expect(
      baoBashCandidates(
        executable: r'C:\Program Files\BaoCode\baocode.exe',
        current: r'C:\Users\me',
      ).take(2),
      [
        r'C:\Program Files\BaoCode\bash\bash.exe',
        r'C:\Users\me\build\bash\bash.exe',
      ],
    );
    expect(
      baoBashCandidates(
        executable:
            r'D:\src\baocode\build\windows\x64\runner\Debug\baocode.exe',
        current: r'C:\Windows\System32',
      ),
      contains(r'D:\src\baocode\build\bash\bash.exe'),
    );
  });
}
