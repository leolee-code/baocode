import 'package:bao_editor/monaco/vs/editor/common/core/position.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/base/uri.dart' show VsUri;
import 'package:baocode/debug/service/debug_service.dart';
import 'package:baocode/ide/ide_layout.dart';
import 'package:baocode/ide/ide_workspace.dart';
import 'package:baocode/ide/services/editors.dart';
import 'package:baocode/ide/workbench/editor_panes.dart';
import 'package:baocode/ide/lsp_ui/problems_panel.dart' show IdePanelTab;
import 'package:baocode/debug/common/debug_types.dart' show debugStateLabel;
import 'package:baocode/ide/services/debug_view.dart';
import 'package:baocode/ide/workbench/actions.dart';
import 'package:baocode/ide/workbench/context_keys.dart';
import 'package:baocode/ide/workbench/contributions.dart';
import 'package:baocode/ide/workbench/contributions/debug.dart';
import 'package:baocode/ide/workbench/services.dart';
import 'package:baocode/ide/workbench/statusbar.dart';
import 'package:baocode/l10n/app_localizations.dart';

import '../../../debug/support/fake_debug_adapter.dart';
import '../fake_files.dart';
import 'fake_host.dart';

/// The debugger as the workbench shows it, alone: the one given followed,
/// its console toggled, and its context key and status bar mark.
void main() {
  testWidgets('follows the debugger given: its sessions, its mark', (
    tester,
  ) async {
    late DebugService service;
    await tester.runAsync(() async {
      service = (await createFakeDebugService()).service;
    });
    addTearDown(service.dispose);
    final host = FakeWorkbenchHost();
    final layout = IdeLayout();
    DebugService? given = service;
    final debug = DebugViewService(
      host: host,
      given: () => given,
      layout: () => layout,
      selection: () => null,
    );
    final services = WorkbenchServices()
      ..add(ActionRegistry())
      ..add(ContextKeyService())
      ..add(StatusbarService())
      ..add<WorkbenchHost>(host)
      ..add(debug);
    final contribution = DebugContribution(services);
    addTearDown(() {
      contribution.dispose();
      services.dispose();
    });
    var changes = 0;
    debug.addListener(() => changes++);
    debug.givenChanged();
    expect(debug.service, same(service));
    expect(debug.inDebugMode, isFalse);
    final keys = services.get<ContextKeyService>();
    expect(keys.getValue('inDebugMode'), isFalse);
    expect(keys.getValue('debugState'), 'inactive');
    expect(keys.getValue('debuggersAvailable'), isTrue);

    // The status bar: no mark until a session is debugged.
    late BuildContext context;
    await tester.pumpWidget(
      Localizations(
        locale: const Locale('en'),
        delegates: AppLocalizations.localizationsDelegates,
        child: Builder(
          builder: (built) {
            context = built;
            return const SizedBox();
          },
        ),
      ),
    );
    final statusbar = services.get<StatusbarService>();
    expect(statusbar.items(context, StatusbarAlignment.left), isEmpty);

    changes = 0;
    await tester.runAsync(
      () => service.startDebugging(
        service.configurationManager.getLaunches().first,
        {
          'type': 'fake',
          'request': 'launch',
          'name': 'Launch main.js',
          'program': r'${workspaceFolder}/main.js',
        },
      ),
    );
    expect(changes, greaterThan(0));
    expect(debug.inDebugMode, isTrue);
    expect(keys.getValue('inDebugMode'), isTrue);
    expect(keys.getValue('debugState'), debugStateLabel(service.state));
    expect(keys.getValue('debugState'), isNot('inactive'));
    expect(
      statusbar.items(context, StatusbarAlignment.left).single.text,
      'Launch main.js',
    );

    // None given: none followed.
    given = null;
    debug.givenChanged();
    expect(debug.service, isNull);
    expect(debug.inDebugMode, isFalse);
    expect(keys.getValue('debugState'), 'inactive');
    expect(keys.getValue('debuggersAvailable'), isFalse);
  });

  testWidgets('the entry is on, its commands upstream\'s ids', (tester) async {
    expect(debugEntryShown, isTrue);
    final host = FakeWorkbenchHost();
    final layout = IdeLayout();
    final debug = DebugViewService(
      host: host,
      given: () => null,
      layout: () => layout,
      selection: () => null,
    );
    final services = WorkbenchServices()
      ..add(ActionRegistry())
      ..add(ContextKeyService())
      ..add(StatusbarService())
      ..add<WorkbenchHost>(host)
      ..add(debug);
    final contribution = DebugContribution(services);
    addTearDown(() {
      contribution.dispose();
      services.dispose();
    });
    final actions = services.get<ActionRegistry>();
    for (final id in const [
      'workbench.view.debug',
      'workbench.action.debug.start',
      'debug.startFromConfig',
      'workbench.action.debug.run',
      'workbench.action.debug.stop',
      'workbench.action.debug.restart',
      'workbench.action.debug.continue',
      'workbench.action.debug.pause',
      'workbench.action.debug.stepOver',
      'workbench.action.debug.stepInto',
      'workbench.action.debug.stepOut',
      'workbench.debug.action.toggleRepl',
      'workbench.action.debug.configure',
      'debug.addConfiguration',
      'editor.debug.action.toggleBreakpoint',
    ]) {
      expect(actions.byId(id), isNotNull, reason: id);
    }
    for (final id in const [
      'debug.start',
      'debug.openConfigFile',
      'workbench.action.toggleRepl',
    ]) {
      expect(actions.byId(id), isNull, reason: id);
    }
    // No debugger: no command runs, and no key says one is there.
    expect(
      actions.byId('workbench.action.debug.start')!.precondition!(services),
      isFalse,
    );
    final keys = services.get<ContextKeyService>();
    expect(keys.getValue('debuggersAvailable'), isFalse);
    expect(keys.getValue('debugState'), 'inactive');
  });

  testWidgets('Toggle Breakpoint: adds then removes one on the caret line', (
    tester,
  ) async {
    late DebugService service;
    await tester.runAsync(() async {
      service = (await createFakeDebugService()).service;
    });
    addTearDown(service.dispose);
    final workspace = IdeWorkspace(
      testRoot,
      files: TreeFiles({inRoot('main.js'): 'a\nb\nc\n', inRoot('n.txt'): 'x'}),
    );
    final host = FakeWorkbenchHost();
    final layout = IdeLayout();
    final panes = EditorPaneRegistry();
    final editors = EditorService(
      host: host,
      panes: panes,
      workspace: () => workspace,
      layout: () => workspace.layout,
      history: () => null,
      focusWorkbench: () {},
    );
    final debug = DebugViewService(
      host: host,
      given: () => service,
      layout: () => layout,
      selection: () => null,
    );
    final services = WorkbenchServices()
      ..add(ActionRegistry())
      ..add(ContextKeyService())
      ..add(StatusbarService())
      ..add<WorkbenchHost>(host)
      ..add(workspace)
      ..add(panes)
      ..add(editors)
      ..add(debug);
    var language = 'javascript';
    final contribution = DebugContribution(
      services,
      languageOf: (_) => language,
    );
    addTearDown(() {
      contribution.dispose();
      services.remove<IdeWorkspace>(owned: false);
      services.dispose();
      workspace.dispose();
    });
    debug.givenChanged();
    final toggle = services.get<ActionRegistry>().byId(
      'editor.debug.action.toggleBreakpoint',
    )!;
    final uri = VsUri.file(inRoot('main.js'));
    void caretAt(int line) => editors.caret.value = (
      position: Position(line, 1),
      statusColumn: 1,
      selectionLength: 0,
      selectionLines: 0,
    );
    List<int> lines() => [
      for (final bp in service.model.getBreakpoints(uri: uri)) bp.lineNumber,
    ];

    // No file open: nothing to toggle.
    expect(toggle.precondition!(services), isFalse);
    await editors.open(inRoot('main.js'));
    await tester.pump();
    expect(toggle.precondition!(services), isTrue);

    caretAt(2);
    await tester.runAsync(() async {
      toggle.run(services, null);
      await until(() => lines().isNotEmpty);
    });
    expect(lines(), [2]);

    // Another line adds another; the same line again removes it.
    caretAt(3);
    await tester.runAsync(() async {
      toggle.run(services, null);
      await until(() => lines().length == 2);
    });
    expect(lines()..sort(), [2, 3]);
    caretAt(2);
    await tester.runAsync(() async {
      toggle.run(services, null);
      await until(() => lines().length == 1);
    });
    expect(lines(), [3]);

    // A file the debugger takes no breakpoints in: none added.
    language = 'plaintext';
    caretAt(1);
    await tester.runAsync(() async {
      toggle.run(services, null);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(lines(), [3]);
    // ...but one there is removed all the same.
    caretAt(3);
    await tester.runAsync(() async {
      toggle.run(services, null);
      await until(() => lines().isEmpty);
    });
    expect(lines(), isEmpty);
  });

  test('Toggle Debug Console: the panel on it, focused, or hidden', () {
    final host = FakeWorkbenchHost();
    final layout = IdeLayout();
    final debug = DebugViewService(
      host: host,
      given: () => null,
      layout: () => layout,
      selection: () => null,
    );
    addTearDown(debug.dispose);
    debug.toggleRepl();
    expect(layout.panel, IdePanelTab.debugConsole);
    expect(host.calls, ['focusPanel']);
    debug.toggleRepl();
    expect(layout.panel, isNull);
    expect(host.calls, ['focusPanel']);
  });
}
