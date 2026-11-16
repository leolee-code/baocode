// The debugger's host in the workbench: the `debug.*` settings and `launch`
// from settings.json, the active editor and its selection, and the editor
// the workbench is asked to show.

import 'dart:io';

import 'package:baocode/debug/adapters/lldb_dap.dart';
import 'package:baocode/debug/adapters/process_list.dart';
import 'package:baocode/debug/common/debug_types.dart';
import 'package:baocode/ide/ide_debug_host.dart';
import 'package:baocode/ide/ide_quick_input.dart';
import 'package:baocode/ide/ide_workspace.dart';
import 'package:baocode/ide/lsp/lsp_protocol.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late IdeWorkspace workspace;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('debug-host');
    File(p.join(dir.path, 'main.py')).writeAsStringSync('one\ntwo three\n');
    workspace = IdeWorkspace(dir.path);
  });
  tearDown(() {
    workspace.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<UserSettings> settings(String json) async {
    final path = p.join(dir.path, 'settings.json');
    File(path).writeAsStringSync(json);
    final settings = UserSettings(path, debounce: Duration.zero);
    addTearDown(settings.dispose);
    await settings.load();
    return settings;
  }

  test(
    'reads debug settings as dotted keys or an object, and launch',
    () async {
      final host = IdeDebugHost(
        workspace: workspace,
        settingsFile: await settings('''{
        // As VS Code writes them.
        "debug.openDebug": "neverOpen",
        "debug.console.maximumLines": 50,
        "launch": {"configurations": [{"name": "Run", "type": "python"}]}
      }'''),
      );
      expect(host.settings().openDebug, 'neverOpen');
      expect(host.settings().repl.maximumLines, 50);
      expect(host.configurationValue('debug'), {
        'openDebug': 'neverOpen',
        'console': {'maximumLines': 50},
      });
      expect(host.userLaunchConfiguration?['configurations'], hasLength(1));
    },
  );

  test('without settings, the defaults', () {
    final host = IdeDebugHost(workspace: workspace);
    expect(host.settings().openDebug, 'openOnDebugBreak');
    expect(host.userLaunchConfiguration, isNull);
  });

  test('a folder\'s project is one workspace folder; a multi-folder '
      'workspace\'s are its folders', () {
    expect(
      IdeDebugHost(workspace: workspace).workspaceFolders
          .map((folder) => (folder.name, folder.index)),
      [(p.basename(dir.path), 0)],
    );
    final first = p.join(dir.path, 'first');
    final second = p.join(dir.path, 'second');
    final multi = IdeWorkspace(
      p.join(dir.path, 'workspace'),
      roots: [first, second],
      gitOf: (_) => null,
    );
    addTearDown(multi.dispose);
    expect(
      IdeDebugHost(workspace: multi).workspaceFolders
          .map((folder) => folder.uri.fsPath()),
      [first, second],
    );
    expect(
      IdeDebugHost(workspace: IdeWorkspace(dir.path, hasFolder: false))
          .workspaceFolders,
      isEmpty,
    );
  });

  test('the active editor with its selection', () async {
    ({int start, int end})? selection = (start: 4, end: 7);
    final host = IdeDebugHost(
      workspace: workspace,
      selectionHost: () => selection,
    );
    expect(host.activeEditor, isNull);

    await workspace.open(p.join(dir.path, 'main.py'));
    var editor = host.activeEditor!;
    expect(editor.uri.fsPath(), p.join(dir.path, 'main.py'));
    expect(editor.selectedText, 'two');
    expect((editor.lineNumber, editor.column), (2, 4));
    expect(host.lastActiveWorkspaceRoot?.fsPath(), p.join(dir.path));

    // Out of its text, or none: no selection.
    selection = (start: 4, end: 99);
    editor = host.activeEditor!;
    expect(editor.selectedText, isNull);
    expect(editor.lineNumber, isNull);
    selection = null;
    expect(host.activeEditor!.selectedText, isNull);
  });

  test('opening an editor shows it, focused unless asked not to', () async {
    final shown = <(String, LspRange?, bool)>[];
    final host = IdeDebugHost(
      workspace: workspace,
      revealHost: (doc, range, {required focus}) =>
          shown.add((doc.path, range, focus)),
    );
    final path = p.join(dir.path, 'main.py');
    final uri = host.workspaceFolders.single.uri.joinPath(['main.py']);

    await host.openEditor(uri);
    expect(workspace.active?.path, path);
    expect(shown, isEmpty);

    await host.openEditor(uri, preserveFocus: false);
    expect(shown, [(path, null, true)]);
  });

  test('asks the workbench to confirm, yes without it', () async {
    expect(await IdeDebugHost(workspace: workspace).confirm('Go?'), isTrue);
    final asked = <String>[];
    final host = IdeDebugHost(
      workspace: workspace,
      confirmHost: (message) async {
        asked.add(message);
        return false;
      },
    );
    expect(await host.confirm('Go?'), isFalse);
    expect(asked, ['Go?']);
  });

  test('opens the debug view and the REPL through the workbench', () {
    final host = IdeDebugHost(workspace: workspace);
    final opened = <String>[];
    host
      ..onOpenDebugView = (() => opened.add('view'))
      ..onOpenRepl = (() => opened.add('repl'))
      ..openDebugView()
      ..openRepl();
    expect(opened, ['view', 'repl']);
  });

  group(r'${command:pickProcess}', () {
    const running = [
      DebugProcess(pid: 311, name: 'server', command: '/srv/bin/server -p 80'),
      DebugProcess(pid: 42, name: 'worker', command: '/srv/bin/worker'),
    ];

    test('lists the processes and gives the id of the one picked', () async {
      IdeQuickPick? shown;
      final host = IdeDebugHost(
        workspace: workspace,
        processes: () async => running,
        pickHost: (model) {
          shown = model as IdeQuickPick;
          final items = shown!.items.whereType<IdeQuickPickItem>().toList();
          shown!.onDidAccept?.call(items[1]);
        },
      );
      expect(await host.executeCommand(pickProcessCommand), '42');
      final items = shown!.items.whereType<IdeQuickPickItem>().toList();
      expect(items.map((item) => item.label), ['server', 'worker']);
      expect(items.first.description, '311  /srv/bin/server -p 80');
      // Typing a pid or a part of the command line finds it.
      expect(shown!.matchOnDescription, isTrue);
      expect(shown!.placeholder, 'Select the process to attach to');
    });

    test('nothing picked ends the start', () async {
      final host = IdeDebugHost(
        workspace: workspace,
        processes: () async => running,
        pickHost: (model) => model.onDidHide?.call(),
      );
      await expectLater(
        host.executeCommand(pickProcessCommand),
        throwsA(isA<DebugCancelledError>()),
      );
    });

    test('no processes: said, and the start ends', () async {
      final host = IdeDebugHost(
        workspace: workspace,
        language: 'zh',
        processes: () async => const [],
        pickHost: (model) => fail('nothing to pick from'),
      );
      await expectLater(
        host.executeCommand(pickProcessCommand),
        throwsA(isA<DebugCancelledError>()),
      );
      expect(workspace.notifications.notifications.map((n) => n.message), [
        '未找到进程。',
      ]);
    });

    test('another command is not its to run', () async {
      final host = IdeDebugHost(workspace: workspace);
      expect(await host.executeCommand('some.other.command'), isNull);
    });
  });

  group('IdeDebug.open', () {
    test('offers LLDB for a project on this machine', () async {
      final debug = await IdeDebug.open(
        workspace: workspace,
        userDirectory: null,
      );
      addTearDown(debug.dispose);
      expect(debug.host.debuggersUnavailable, isNull);
      expect(debug.service.registry.getDebugger(lldbDapType), isNotNull);
    }, testOn: 'mac-os');
  });
}
