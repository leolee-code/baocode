// The workspace's debugger as the workbench shows it (upstream
// `DebugService` with debug.contribution.ts's views): the one given, else
// one made for the workspace once the display language can be read; Run
// and Debug's view, its console in the panel, and the editor shown where a
// session stops.

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../debug/common/debug_types.dart';
import '../../debug/service/debug_service.dart';
import '../../debug/ui/run_and_debug_view.dart';
import '../../l10n/l10n.dart';
import '../../platform/data_dir.dart';
import '../../settings/user_settings.dart';
import '../debug_terminal.dart';
import '../ide_debug_host.dart';
import '../ide_dialog.dart';
import '../ide_layout.dart';
import '../ide_workspace.dart';
import '../lsp_ui/problems_panel.dart' show IdePanelTab;
import '../terminal/terminal_instance.dart' show TerminalLaunchConfig;
import '../terminal/terminal_service.dart';
import '../workbench/contributions.dart';
import '../workbench/views.dart';

/// Whether Run and Debug is offered: its activity bar item and its
/// commands.
const debugEntryShown = true;

class DebugViewService extends ChangeNotifier {
  /// Over [given] (the window's [IdeWorkbench.debugService]), else one of
  /// its own per workspace; the panel is [layout]'s, the editor's
  /// selection [selection]'s.
  DebugViewService({
    required this.host,
    required this._given,
    required this._layout,
    required this._selection,
    this.settings,
    this.terminals,
  });

  final WorkbenchHost host;
  final UserSettings? settings;

  /// The panel's terminals, for what a debugger runs in one
  /// (`runInTerminal`); none where they cannot run.
  final TerminalService? Function()? terminals;
  final DebugService? Function() _given;
  final IdeLayout Function() _layout;

  /// The active editor's selection, as offsets.
  final ({int start, int end})? Function() _selection;

  /// The debugger made for the workspace, when none is given.
  IdeDebug? _owned;
  IdeWorkspace? _workspace;
  DebugService? _listened;

  /// The debugger: the one given, else the workspace's.
  DebugService? get service => _given() ?? _owned?.service;

  /// Run and Debug's view, which its commands act in.
  final runAndDebugKey = GlobalKey<RunAndDebugViewState>();

  /// Whether a session is debugged (`inDebugMode`).
  bool get inDebugMode =>
      (service?.state ?? DebugState.inactive) != DebugState.inactive;

  /// Whether the toolbar is docked, over the editor
  /// (`debug.toolBarLocation`).
  bool get toolbarDocked => service?.settings().toolBarLocation == 'docked';

  /// What the debugger does follows it; another given, the one followed.
  void givenChanged() => _follow();

  void _follow() {
    final debug = service;
    if (identical(debug, _listened)) return;
    _listened?.removeListener(notifyListeners);
    _listened = debug?..addListener(notifyListeners);
    notifyListeners();
  }

  /// Makes [workspace]'s debugger once the display language can be read,
  /// unless one is given.
  void attach(IdeWorkspace workspace) {
    _workspace = workspace;
    _follow();
    if (_given() != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final context = host.context;
      if (context == null || !identical(_workspace, workspace)) return;
      final l10n = context.l10n;
      final debug = await IdeDebug.open(
        workspace: workspace,
        userDirectory: DataDirectory.current.userDir,
        settings: settings,
        language: Localizations.localeOf(context).languageCode,
        pick: (model) {
          if (host.context != null) host.showQuickModel(model);
        },
        confirm: (message) async {
          final context = host.context;
          if (context == null) return false;
          final pick = await showIdeDialog(
            context,
            message: message,
            buttons: [l10n.commonOk],
          );
          return pick == 0;
        },
        selection: _selection,
        runInTerminal: _runInTerminal,
        openTerminal: ({title, cwd}) async => switch (terminals?.call()) {
          final terminals? => openDebugTerminal(
            terminals,
            title: title,
            cwd: cwd,
          ),
          null => null,
        },
        reveal: (doc, range, {required focus}) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (host.context == null || !identical(workspace.active, doc)) {
              return;
            }
            _layout().showEditor();
            if (range != null) host.revealRange(range, select: true);
            if (focus) host.focusEditor();
          });
          WidgetsBinding.instance.scheduleFrame();
        },
      );
      if (host.context == null ||
          !identical(_workspace, workspace) ||
          _given() != null ||
          _owned != null) {
        await debug.dispose();
        return;
      }
      debug.host
        ..onOpenDebugView = (() => host.showView(IdeSideView.debug))
        ..onOpenRepl = (() => _layout().panel = IdePanelTab.debugConsole);
      workspace.onSaved = debug.saved;
      _owned = debug;
      _follow();
    });
  }

  /// What a debug adapter asks to run in a terminal (DAP's `runInTerminal`,
  /// lldb-dap's launcher of the program debugged): a terminal of the
  /// panel's that runs it, shown, and kept once the program exits until a
  /// key is pressed, for what it printed. Its process id is not told: the
  /// adapter does without.
  Future<int?> _runInTerminal(Json args, String sessionId) async {
    final terminals = this.terminals?.call();
    final command = [
      for (final argument in args.list('args') ?? const <Object?>[])
        if (argument is String) argument,
    ];
    if (terminals == null || command.isEmpty) {
      throw StateError('No terminal to run the program in.');
    }
    final instance = terminals.create(
      config: TerminalLaunchConfig(
        name: args.str('title'),
        executable: command.first,
        arguments: command.sublist(1),
        cwd: args.str('cwd'),
        env: switch (args.obj('env')) {
          final env? => {
            for (final MapEntry(:key, :value) in env.entries)
              key: value is String ? value : null,
          },
          null => null,
        },
        waitOnExit: (_) => null,
      ),
    );
    terminals.show(instance);
    return null;
  }

  /// [workspace] left: its debugger disposed.
  void detach(IdeWorkspace workspace) {
    workspace.onSaved = null;
    _workspace = null;
    final debug = _owned;
    _owned = null;
    _follow();
    if (debug != null) unawaited(debug.dispose());
  }

  /// [action] in Run and Debug's view, shown first.
  void runAndDebug(Future<void> Function(RunAndDebugViewState view) action) {
    host.showView(IdeSideView.debug);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (host.context == null) return;
      final view = runAndDebugKey.currentState;
      if (view != null) unawaited(action(view));
    });
  }

  /// Toggle Debug Console: the panel on it, with the keyboard, or hidden.
  void toggleRepl() {
    final layout = _layout();
    layout.panel = layout.panel == IdePanelTab.debugConsole
        ? null
        : IdePanelTab.debugConsole;
    if (layout.panel == IdePanelTab.debugConsole) host.focusPanel();
  }

  @override
  void dispose() {
    _listened?.removeListener(notifyListeners);
    _listened = null;
    if (_owned case final debug?) unawaited(debug.dispose());
    _owned = null;
    super.dispose();
  }
}
