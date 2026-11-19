import 'dart:async';

import 'package:bao_editor/monaco/vs/editor/common/core/position.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/ide_layout.dart';
import 'package:baocode/ide/ide_notifications.dart';
import 'package:baocode/ide/ide_workspace.dart';
import 'package:baocode/ide/lsp/language_features.dart';
import 'package:baocode/ide/lsp/lsp_protocol.dart';
import 'package:baocode/ide/lsp_ui/lsp_convert.dart';
import 'package:baocode/ide/lsp_ui/problems_panel.dart';
import 'package:baocode/ide/lsp_ui/workspace_symbols.dart';
import 'package:baocode/ide/services/language.dart';
import 'package:baocode/ide/services/problems.dart';
import 'package:baocode/ide/services/references.dart';
import 'package:baocode/ide/workbench/actions.dart';
import 'package:baocode/ide/workbench/context_keys.dart';
import 'package:baocode/ide/workbench/contributions.dart';
import 'package:baocode/ide/workbench/contributions/language.dart';
import 'package:baocode/ide/workbench/services.dart';
import 'package:baocode/ide/workbench/statusbar.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:path/path.dart' as p;

import '../../lsp_ui/fake_language_features.dart';
import '../fake_files.dart';
import 'fake_host.dart';

LspRange _at(int line, int start, int end) =>
    LspRange(LspPosition(line, start), LspPosition(line, end));

/// The language servers' services alone, over a workspace with scripted
/// servers: the servers' edits, the workspace's symbols searched, the
/// problems stepped through and counted, the references stepped through,
/// and their context keys.
void main() {
  late FakeLanguageFeatures languages;
  late IdeWorkspace workspace;
  late FakeWorkbenchHost host;
  late IdeLayout layout;
  late LanguageService language;
  late ProblemsService problems;
  late ReferencesService references;
  late WorkbenchServices services;
  var caret = const Position(1, 1);
  final applied = <LspWorkspaceEdit>[];
  var hovers = 0;

  Future<void> setUpServices(WidgetTester tester) async {
    languages = FakeLanguageFeatures();
    workspace = IdeWorkspace(
      testRoot,
      files: TreeFiles({inRoot('a.dart'): 'a\nb\nc', inRoot('b.dart'): 'b'}),
      languages: languages,
    );
    host = FakeWorkbenchHost();
    layout = IdeLayout();
    caret = const Position(1, 1);
    applied.clear();
    hovers = 0;
    language = LanguageService(
      host: host,
      caret: () => caret,
      applyEdit: (edit) async {
        applied.add(edit);
        return true;
      },
      ignored: () => const {},
    );
    problems = ProblemsService(
      host: host,
      language: language,
      layout: () => layout,
      caret: () => caret,
      activePath: () => workspace.active?.path,
      showHover: () => hovers++,
    );
    references = ReferencesService(
      host: host,
      layout: () => layout,
      caret: () => caret,
      activePath: () => workspace.active?.path,
    );
    services = WorkbenchServices()
      ..add(ActionRegistry())
      ..add(ContextKeyService())
      ..add(StatusbarService())
      ..add<WorkbenchHost>(host)
      ..add(workspace)
      ..add(language)
      ..add(problems)
      ..add(references);
    final contribution = LanguageContribution(services);
    language.attach(workspace);
    await tester.pumpWidget(
      Localizations(
        locale: const Locale('en'),
        delegates: AppLocalizations.localizationsDelegates,
        child: Builder(
          builder: (context) {
            host.context = context;
            return const SizedBox();
          },
        ),
      ),
    );
    addTearDown(() {
      contribution.dispose();
      services.remove<IdeWorkspace>(owned: false);
      services.dispose();
      workspace.dispose();
      languages.dispose();
    });
  }

  testWidgets('a server\'s edits are applied, and answered', (tester) async {
    await setUpServices(tester);
    final edit = LspWorkspaceEdit(const {});
    // Heard in the test's zone, as the window's are.
    bool? answer;
    unawaited(languages.requestApplyEdit(edit).then((a) => answer = a));
    await tester.pump();
    expect(answer, isTrue);
    expect(applied, [same(edit)]);
  });

  testWidgets('workspace symbols: asked once the typing rests, the last '
      'query\'s answer kept, opened where they are', (tester) async {
    await setUpServices(tester);
    final symbols = language.workspaceSymbols!;
    final answers = <String, Completer<List<LspWorkspaceSymbol>>>{};
    languages.onWorkspaceSymbols = (query) =>
        (answers[query] = Completer()).future;
    var changes = 0;
    symbols.addListener(() => changes++);
    LspWorkspaceSymbol symbol(String name, String path, [LspRange? range]) =>
        LspWorkspaceSymbol(
          name: name,
          kind: LspSymbolKind.function,
          uri: Uri.file(path).toString(),
          range: range,
        );

    // Typed on before the delay is over: asked once, for what is there.
    symbols.search('f');
    expect(symbols.loading, isTrue);
    await tester.pump(const Duration(milliseconds: 100));
    symbols.search('fo');
    await tester.pump(const Duration(milliseconds: 100));
    expect(languages.requests, isEmpty);
    await tester.pump(const Duration(milliseconds: 50));
    expect(languages.requests, ['workspaceSymbols fo']);

    // An answer to a query no longer the one typed is not kept.
    symbols.search('foo');
    await tester.pump(IdeWorkspaceSymbols.delay);
    answers['fo']!.complete([symbol('fo', inRoot('a.dart'))]);
    await tester.pump();
    expect(symbols.symbols, isEmpty);
    expect(symbols.loading, isTrue);
    expect(changes, 0);
    final outside = p.join(p.dirname(testRoot), 'sdk', 'c.dart');
    answers['foo']!.complete([
      symbol('foo', inRoot('b.dart'), _at(2, 4, 7)),
      symbol('food', outside),
    ]);
    await tester.pump();
    expect(symbols.loading, isFalse);
    expect(symbols.symbols.map((s) => s.name), ['foo', 'food']);
    expect(changes, 1);

    // The same query again asks nothing.
    symbols.search(' foo ');
    expect(symbols.loading, isFalse);
    await tester.pump(IdeWorkspaceSymbols.delay);
    expect(languages.count('workspaceSymbols'), 2);

    // Named from the workspace's folder; opened at its start, the top of
    // the file of one without a place.
    final [inside, elsewhere] = symbols.symbols;
    expect(language.workspaceSymbolFile(inside), 'b.dart');
    expect(language.workspaceSymbolFile(elsewhere), outside);
    language
      ..openWorkspaceSymbol(inside)
      ..openWorkspaceSymbol(elsewhere);
    expect(host.locations, [
      IdeLocation(inRoot('b.dart'), _at(2, 4, 4)),
      IdeLocation(outside, _at(0, 0, 0)),
    ]);

    // Emptied: nothing kept, nothing asked.
    symbols.search('');
    expect(symbols.symbols, isEmpty);
    expect(symbols.loading, isFalse);
    await tester.pump(IdeWorkspaceSymbols.delay);
    expect(languages.count('workspaceSymbols'), 2);
  });

  testWidgets('workspace symbols: none without a server that searches them, '
      'asked once one runs', (tester) async {
    await setUpServices(tester);
    final symbols = language.workspaceSymbols!;
    languages
      ..workspaceSymbolsSupported = false
      ..onWorkspaceSymbols = (query) => [
        LspWorkspaceSymbol(
          name: query,
          kind: LspSymbolKind.klass,
          uri: Uri.file(inRoot('a.dart')).toString(),
        ),
      ];
    var changes = 0;
    symbols.addListener(() => changes++);
    symbols.search('foo');
    expect(symbols.supported, isFalse);
    expect(symbols.loading, isFalse);
    await tester.pump(IdeWorkspaceSymbols.delay);
    expect(languages.requests, isEmpty);

    // A server started.
    languages
      ..workspaceSymbolsSupported = true
      ..setStatus(inRoot('a.dart'), const []);
    expect(symbols.loading, isTrue);
    expect(changes, 1);
    await tester.pump(IdeWorkspaceSymbols.delay);
    await tester.pump();
    expect(symbols.symbols.single.name, 'foo');
    expect(changes, 2);

    // It stopped: its answer goes.
    languages
      ..workspaceSymbolsSupported = false
      ..setStatus(inRoot('a.dart'), const []);
    expect(symbols.symbols, isEmpty);
    expect(changes, 3);
  });

  testWidgets('switch source/header: enabled for a document clangd serves, '
      'opens the counterpart, says when there is none', (tester) async {
    await setUpServices(tester);
    final registry = services.get<ActionRegistry>();
    final statusbar = services.get<StatusbarService>();
    final action = registry.byId('clangd.switchheadersource')!;
    bool enabled() => action.precondition!(services);
    Future<void> run() async {
      action.run(services, null);
      await tester.pump();
    }

    // No document is active.
    languages.clangdServes = true;
    expect(enabled(), isFalse);
    await workspace.open(inRoot('a.dart'));
    languages.clangdServes = false;
    expect(enabled(), isFalse);

    languages.clangdServes = true;
    expect(enabled(), isTrue);
    languages.onSwitchSourceHeader = (path) => inRoot('a.h');
    await run();
    expect(languages.requests, ['switchSourceHeader ${inRoot('a.dart')}']);
    expect(host.calls, contains('openFile ${inRoot('a.h')}'));
    expect(statusbar.message, isNull);

    languages.onSwitchSourceHeader = (path) => null;
    host.calls.clear();
    await run();
    expect(host.calls.where((c) => c.startsWith('openFile')), isEmpty);
    expect(
      statusbar.message,
      'No source or header counterpart found for this file.',
    );
    // Hidden after a while.
    await tester.pump(const Duration(seconds: 4));
    expect(statusbar.message, isNull);
  });

  testWidgets('problems: counted, stepped through across files, with the '
      'hover', (tester) async {
    await setUpServices(tester);
    final keys = services.get<ContextKeyService>();
    final statusbar = services.get<StatusbarService>();
    String counts() =>
        statusbar.items(host.context!, StatusbarAlignment.left).first.text;
    expect(counts(), r'$(error) 0 $(warning) 0');
    languages
      ..setDiagnostics(inRoot('a.dart'), [
        LspDiagnostic(range: _at(1, 0, 1), message: 'one'),
      ])
      ..setDiagnostics(inRoot('b.dart'), [
        LspDiagnostic(
          range: _at(0, 0, 1),
          message: 'two',
          severity: LspDiagnosticSeverity.warning,
        ),
      ]);
    expect(counts(), r'$(error) 1 $(warning) 1');

    await workspace.open(inRoot('a.dart'));
    problems.go(next: true);
    await tester.pump();
    expect(host.calls, ['openLocation ${inRoot('a.dart')}']);
    expect(hovers, 1);
    problems.go(next: true);
    expect(host.calls.last, 'openLocation ${inRoot('b.dart')}');

    // Toggle Problems: shown with the keyboard; the status bar's toggles.
    expect(keys.getValue('problemsVisibility'), isFalse);
    services
        .get<ActionRegistry>()
        .byId('workbench.actions.view.problems')!
        .run(services, null);
    expect(layout.panel, IdePanelTab.problems);
    expect(keys.getValue('problemsVisibility'), isTrue);
    expect(keys.getValue('problemFocus'), isFalse);
    problems.togglePanel();
    expect(layout.panel, isNull);
  });

  testWidgets('references: shown in the panel, stepped through from the '
      'nearest', (tester) async {
    await setUpServices(tester);
    final keys = services.get<ContextKeyService>();
    final actions = services.get<ActionRegistry>();
    bool enabled(String id) => actions.byId(id)!.precondition!(services);
    expect(keys.getValue('reference-list.isActive'), isFalse);
    expect(enabled('references-view.next'), isFalse);

    await workspace.open(inRoot('a.dart'));
    references.show('References', [
      IdeLocation(inRoot('a.dart'), _at(0, 0, 1)),
      IdeLocation(inRoot('a.dart'), _at(2, 0, 1)),
      IdeLocation(inRoot('b.dart'), _at(0, 0, 1)),
    ]);
    expect(layout.panel, IdePanelTab.references);
    expect(keys.getValue('reference-list.hasResult'), isTrue);
    expect(enabled('references-view.next'), isTrue);

    // From the caret's (line 2: the first after it is line 3's), on.
    caret = const Position(2, 1);
    references.go(next: true);
    await tester.pump();
    expect(host.calls, ['openLocation ${inRoot('b.dart')}', 'focusEditor']);
    expect(references.list.focused, isA<IdeLocation>());

    actions.byId('references-view.clear')!.run(services, null);
    expect(references.references, isNull);
    expect(keys.getValue('reference-list.isActive'), isFalse);
  });

  testWidgets(
    'server error/warning messages notify with log and settings actions',
    (tester) async {
      await setUpServices(tester);
      languages.logs['jdtls'] = [
        '[status] Starting: Importing Maven project...',
        '[status] Error: Non-resolvable parent POM',
      ];
      languages.emitServerMessage(
        LspServerMessage(
          serverId: 'jdtls',
          type: LspMessageType.error,
          message: 'Non-resolvable parent POM',
          path: inRoot('a.dart'),
        ),
      );
      await tester.pump();

      expect(workspace.notifications.notifications.length, 1);
      final notice = workspace.notifications.notifications.single;
      expect(notice.severity, IdeSeverity.error);
      expect(notice.source, 'jdtls');
      expect(notice.message, '[jdtls] Non-resolvable parent POM');
      expect(notice.primary.map((a) => a.label), [
        'View Log',
        'Open LSP Settings',
      ]);

      // View Log opens a read-only revision tab with the server's log.
      notice.primary[0].run();
      await tester.pump();
      final logDoc = workspace.active!;
      expect(logDoc.readOnly, isTrue);
      expect(logDoc.name, 'jdtls.log');
      expect(
        logDoc.text,
        '[status] Starting: Importing Maven project...\n'
        '[status] Error: Non-resolvable parent POM',
      );

      // Reopening View Log refreshes the tab with newly appended lines.
      languages.logs['jdtls']!.add('[stderr] retry failed');
      await language.openServerLog('jdtls', path: inRoot('a.dart'));
      expect(workspace.active, same(logDoc));
      expect(logDoc.text, contains('[stderr] retry failed'));

      // Open LSP Settings invokes the command.
      notice.primary[1].run();
      expect(
        host.calls,
        contains('executeCommand baocode.openLspSettings null'),
      );

      languages.emitServerMessage(
        const LspServerMessage(
          serverId: 'jdtls',
          type: LspMessageType.warning,
          message: 'Using fallback JDK',
        ),
      );
      await tester.pump();
      expect(
        workspace.notifications.notifications.first.severity,
        IdeSeverity.warning,
      );

      // Informational traffic is logged, not turned into toasts.
      languages.emitServerMessage(
        const LspServerMessage(
          serverId: 'jdtls',
          type: LspMessageType.info,
          message: 'Ready',
        ),
      );
      await tester.pump();
      expect(workspace.notifications.notifications, hasLength(2));

      language.detach();
      languages.emitServerMessage(
        const LspServerMessage(
          serverId: 'jdtls',
          type: LspMessageType.error,
          message: 'Late message',
        ),
      );
      await tester.pump();
      expect(workspace.notifications.notifications, hasLength(2));
    },
  );
}
