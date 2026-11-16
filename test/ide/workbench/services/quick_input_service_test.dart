import 'package:bao_editor/monaco/vs/editor/common/core/position.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/ide_commands.dart';
import 'package:baocode/ide/ide_quick_input.dart';
import 'package:baocode/ide/ide_workspace.dart';
import 'package:baocode/ide/lsp/lsp_protocol.dart';
import 'package:baocode/ide/lsp_ui/lsp_convert.dart';
import 'package:baocode/ide/lsp_ui/workspace_symbols.dart';
import 'package:baocode/ide/services/commands.dart';
import 'package:baocode/ide/services/language.dart';
import 'package:baocode/ide/services/quick_input.dart';
import 'package:baocode/ide/workbench/actions.dart';
import 'package:baocode/ide/workbench/contributions/quick_input.dart';
import 'package:baocode/ide/workbench/quick_access.dart';
import 'package:baocode/ide/workbench/services.dart';
import 'package:baocode/l10n/app_localizations.dart';

import '../../lsp_ui/fake_language_features.dart';
import '../fake_files.dart';
import 'fake_host.dart';

/// The quick input and the commands alone: a text's provider by its
/// prefix, opened and switched, a pick in its place, closed with the
/// keyboard back; the workspace's symbols listed as the servers answer;
/// the commands of the actions and of the sources.
void main() {
  late FakeWorkbenchHost host;
  late QuickAccessRegistry registry;
  late QuickInputService quick;
  var workbenchFocused = 0;

  Future<void> setUpQuick(WidgetTester tester) async {
    host = FakeWorkbenchHost();
    registry = QuickAccessRegistry();
    workbenchFocused = 0;
    quick = QuickInputService(
      host: host,
      registry: registry,
      focusWorkbench: () => workbenchFocused++,
    );
    addTearDown(quick.dispose);
    QuickAccessProvider provider(String prefix, {String? key}) =>
        QuickAccessProvider(
          prefix: prefix,
          contextKey: key,
          placeholder: (_) => 'in "$prefix"',
          picks: (_, filter) => [IdeQuickPickItem(label: '$prefix|$filter')],
        );
    registry
      ..register(provider('', key: 'inFilesPicker'))
      ..register(provider('>'))
      ..register(provider('edt ', key: 'inEditorsPicker'))
      ..register(provider('edt mru ', key: 'inEditorsPicker'));
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
  }

  testWidgets('a text\'s provider: the longest prefix it starts with', (
    tester,
  ) async {
    await setUpQuick(tester);
    expect(quick.picks('foo').single.label, '|foo');
    expect(quick.picks('>run').single.label, '>|run');
    expect(quick.picks('edt a').single.label, 'edt |a');
    expect(quick.picks('edt mru a').single.label, 'edt mru |a');
    expect(quick.placeholder('>'), 'in ">"');
  });

  testWidgets('opened, a pick in its place, closed: the keyboard back', (
    tester,
  ) async {
    await setUpQuick(tester);
    var changes = 0;
    quick.addListener(() => changes++);
    expect(quick.contextKey('inQuickOpen'), isFalse);
    expect(quick.contextKey('inFilesPicker'), isFalse);
    expect(quick.contextKey('someoneElses'), isNull);

    quick.show('');
    expect(quick.isOpen, isTrue);
    expect(quick.text, '');
    expect(quick.activation, IdeQuickPickFocus.first);
    expect(quick.contextKey('inFilesPicker'), isTrue);
    expect(quick.contextKey('inEditorsPicker'), isFalse);
    expect(quick.contextKey('quickInputType'), 'quickPick');

    // With a quick navigation: the second row first, the input hidden
    // only if none showed.
    quick.show('edt mru ', quickNavigate: const []);
    expect(quick.activation, IdeQuickPickFocus.second);
    expect(quick.hideInput, isFalse);
    expect(quick.contextKey('inEditorsPicker'), isTrue);

    var hidden = 0;
    quick.showModel(
      IdeQuickInputBox(onDidAccept: (_) {}, onDidHide: () => hidden++),
    );
    expect(quick.text, isNull);
    expect(quick.contextKey('quickInputType'), 'inputBox');
    expect(quick.contextKey('inFilesPicker'), isFalse);

    quick.close();
    expect(quick.isOpen, isFalse);
    expect(hidden, 1);
    expect(workbenchFocused, 1);
    expect(changes, 4);
    // Closed already: nothing.
    quick.close();
    expect(workbenchFocused, 1);
  });

  testWidgets('#: the workspace\'s symbols as the servers answer, opened '
      'where they are', (tester) async {
    await setUpQuick(tester);
    final languages = FakeLanguageFeatures();
    final workspace = IdeWorkspace(
      testRoot,
      files: TreeFiles({inRoot('lib/a.dart'): ''}),
      languages: languages,
    );
    final language = LanguageService(
      host: host,
      caret: () => const Position(1, 1),
      applyEdit: (_) async => true,
      ignored: () => const {},
    )..attach(workspace);
    final services = WorkbenchServices()..add(language);
    addTearDown(() {
      services.dispose();
      workspace.dispose();
      languages.dispose();
    });
    registry.register(QuickInputContribution.workspaceSymbols(services));
    final header = Uri.file(inRoot('include/b.h')).toString();
    languages.onWorkspaceSymbols = (query) => [
      LspWorkspaceSymbol(name: 'Other', kind: LspSymbolKind.klass, uri: header),
      LspWorkspaceSymbol(
        name: 'fooBar',
        kind: LspSymbolKind.function,
        uri: Uri.file(inRoot('lib/a.dart')).toString(),
        range: lspRange(3, 2, 8),
        containerName: 'Baz',
      ),
      LspWorkspaceSymbol(
        name: 'unfold',
        kind: LspSymbolKind.function,
        uri: header,
        range: lspRange(1, 0, 6),
      ),
    ];
    List<(String, String?)> rows(String text) => [
      for (final row in quick.picks(text)) (row.label, row.description),
    ];

    quick.show('#');
    var refreshed = 0;
    quick.refresh.addListener(() => refreshed++);
    expect(quick.placeholder('#'), 'Type the name of a symbol to open.');
    expect(quick.picks('#'), isEmpty);

    // Typed: asked once the typing rests, its rows listed as the answer
    // comes.
    expect(rows('#fo'), [('Loading symbols…', null)]);
    expect(quick.picks('#fo').single.onAccept, isNull);
    await tester.pump(IdeWorkspaceSymbols.delay);
    await tester.pump();
    expect(languages.requests, ['workspaceSymbols fo']);
    expect(refreshed, 1);
    // Those whose name matches first, the best first; then what the
    // server matched otherwise.
    expect(rows('#fo'), [
      ('fooBar', 'Baz • lib/a.dart'),
      ('unfold', 'include/b.h'),
      ('Other', 'include/b.h'),
    ]);
    final picked = quick.picks('#fo').first;
    expect(picked.labelMatches, [0, 1]);
    expect(picked.icon, isA<Icon>());
    picked.onAccept!();
    expect(
      host.locations.single,
      IdeLocation(inRoot('lib/a.dart'), lspRange(3, 2, 2)),
    );

    // Typed on: the rows there that still match, until the answer.
    expect(rows('#foo'), [('fooBar', 'Baz • lib/a.dart')]);
    languages.onWorkspaceSymbols = (_) => const [];
    expect(rows('#fooz'), [('Loading symbols…', null)]);
    await tester.pump(IdeWorkspaceSymbols.delay);
    await tester.pump();
    expect(languages.requests, [
      'workspaceSymbols fo',
      'workspaceSymbols fooz',
    ]);
    expect(rows('#fooz'), [('No matching workspace symbols', null)]);

    // Opened again: asked again.
    quick.show('#');
    expect(rows('#fooz'), [('Loading symbols…', null)]);
    await tester.pump(IdeWorkspaceSymbols.delay);
    await tester.pump();
    expect(languages.count('workspaceSymbols'), 3);

    // No server that searches them.
    languages.workspaceSymbolsSupported = false;
    quick.show('#');
    final none = quick.picks('#').single;
    expect(
      none.label,
      'No running language server can search the workspace\'s symbols.',
    );
    expect(none.onAccept, isNull);
    expect(quick.picks('#foo').single.label, none.label);
    await tester.pump(IdeWorkspaceSymbols.delay);
    expect(languages.count('workspaceSymbols'), 3);
  });

  test('commands: the actions\' first, then the sources\', by id', () {
    final services = WorkbenchServices();
    final actions = services.add(ActionRegistry());
    final commands = CommandService(services: services, actions: actions);
    final ran = <String>[];
    actions.registerAll([
      WorkbenchAction(id: 'a', title: 'A', run: (_, _) => ran.add('a')),
      WorkbenchAction(
        id: 'hidden',
        title: 'Hidden',
        palette: false,
        run: (_, _) => ran.add('hidden'),
      ),
    ]);
    commands
      ..addSource(
        () => [
          IdeCommand(id: 'a', label: 'Other A', run: () => ran.add('a2')),
          IdeCommand(id: 'b', label: 'B', run: () => ran.add('b')),
        ],
      )
      ..addSource(
        () => [
          IdeCommand(
            id: 'off',
            label: 'Off',
            enabled: false,
            run: () => ran.add('off'),
          ),
        ],
        palette: false,
      );
    expect(commands.palette().map((command) => command.id), ['a', 'a', 'b']);
    expect(commands.byId().keys, ['a', 'hidden', 'b', 'off']);
    expect(commands.runById('a'), isTrue);
    expect(commands.runById('hidden'), isTrue);
    expect(commands.runById('off'), isFalse);
    expect(commands.runById('none'), isFalse);
    expect(ran, ['a', 'hidden']);
    expect(commands.recent.items, ['hidden', 'a']);
    services.dispose();
  });
}
