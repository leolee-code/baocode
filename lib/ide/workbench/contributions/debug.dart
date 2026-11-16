// The debugger's commands (debugCommands.ts, debug.contribution.ts,
// debugEditorActions.ts), its context keys (`inDebugMode`, `debugState`,
// `debuggersAvailable`), and the status bar's mark of a session debugged
// (statusbarColorProvider.ts), over the window's DebugViewService.

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../base/uri.dart' show VsUri;
import '../../../debug/common/debug_model.dart' show Thread;
import '../../../debug/common/debug_types.dart';
import '../../../debug/ui/debug_strings.dart';
import '../../../debug/ui/debug_toolbar.dart' show debugActionThread;
import '../../../keybindings/keybinding_service.dart';
import '../../../theme/codicons.dart';
import '../../../theme/workbench_theme.dart' show themeColors;
import '../../debug_editor_glue.dart' show debugToggleBreakpoint;
import '../../ide_status_bar.dart';
import '../../ide_workspace.dart';
import '../../services/debug_view.dart';
import '../../services/editors.dart';
import '../actions.dart';
import '../context_keys.dart';
import '../contributions.dart';
import '../services.dart';
import '../statusbar.dart';
import '../views.dart';

/// The status bar's debugging mark: right of the remote's entry.
const debuggingPriority = 90.0;

class DebugContribution extends WorkbenchRegistrations {
  /// [languageOf] tells the language of the active document (to know
  /// whether it takes breakpoints): the text editor's, once known.
  DebugContribution(
    WorkbenchServices services, {
    String? Function(WorkbenchServices services)? languageOf,
  }) {
    final debug = services.get<DebugViewService>();
    final host = services.get<WorkbenchHost>();
    bool hasDebugger(WorkbenchServices _) => debug.service != null;
    bool stopped(WorkbenchServices _) =>
        debug.service != null && debugActionThread(debug.service!) != null;
    IdeDocument? activeFile() {
      final active = services.find<IdeWorkspace>()?.active;
      return active != null && active.isFile ? active : null;
    }

    /// One on the thread stepped (the focused one, else the first stopped).
    WorkbenchAction step(String id, Future<void> Function(Thread thread) run) =>
        WorkbenchAction.catalog(
          'workbench.action.debug.$id',
          precondition: stopped,
          run: (_, _) {
            final thread = switch (debug.service) {
              final service? => debugActionThread(service),
              null => null,
            };
            if (thread != null) unawaited(run(thread));
          },
        );

    if (debugEntryShown) {
      add(
        services.get<ActionRegistry>().registerAll([
          WorkbenchAction.catalog(
            'workbench.view.debug',
            precondition: hasDebugger,
            run: (_, _) => host.showView(IdeSideView.debug),
          ),
          WorkbenchAction.catalog(
            'workbench.action.debug.start',
            precondition: hasDebugger,
            run: (_, _) => debug.runAndDebug((view) => view.start()),
          ),
          WorkbenchAction.catalog(
            'debug.startFromConfig',
            precondition: hasDebugger,
            takesArgs: true,
            run: (_, args) {
              final config = args is Map ? args.cast<String, Object?>() : null;
              debug.runAndDebug((view) => view.start(config: config));
            },
          ),
          WorkbenchAction.catalog(
            'debug.addConfiguration',
            precondition: hasDebugger,
            run: (_, _) => debug.runAndDebug((view) => view.addConfiguration()),
          ),
          WorkbenchAction.catalog(
            'workbench.action.debug.configure',
            precondition: hasDebugger,
            run: (_, _) => debug.runAndDebug((view) => view.openConfigFile()),
          ),
          WorkbenchAction.catalog(
            'workbench.action.debug.run',
            precondition: hasDebugger,
            run: (_, _) =>
                debug.runAndDebug((view) => view.runWithoutDebugging()),
          ),
          WorkbenchAction.catalog(
            'workbench.debug.action.toggleRepl',
            precondition: hasDebugger,
            run: (_, _) => debug.toggleRepl(),
          ),
          WorkbenchAction.catalog(
            'workbench.action.debug.stop',
            precondition: hasDebugger,
            run: (_, _) => unawaited(debug.service?.stopSession(null)),
          ),
          WorkbenchAction.catalog(
            'workbench.action.debug.restart',
            precondition: (_) =>
                debug.service?.viewModel.focusedSession != null,
            run: (_, _) {
              final service = debug.service;
              final session = service?.viewModel.focusedSession;
              if (session != null) unawaited(service!.restartSession(session));
            },
          ),
          step('continue', (thread) => thread.continue_()),
          step('pause', (thread) => thread.pause()),
          step('stepOver', (thread) => thread.next()),
          step('stepInto', (thread) => thread.stepIn()),
          step('stepOut', (thread) => thread.stepOut()),
          // The caret's line, as a click on its glyph.
          WorkbenchAction.catalog(
            'editor.debug.action.toggleBreakpoint',
            precondition: (_) => hasDebugger(services) && activeFile() != null,
            run: (_, _) {
              final service = debug.service;
              final doc = activeFile();
              if (service == null || doc == null) return;
              final language =
                  languageOf?.call(services) ??
                  services.find<EditorService>()?.editor?.languageId;
              unawaited(
                debugToggleBreakpoint(
                  service,
                  VsUri.file(doc.path),
                  services.get<EditorService>().position.lineNumber,
                  language,
                ),
              );
            },
          ),
        ]),
      );
    }
    add(
      services.get<ContextKeyService>().addProvider(
        (key) => switch (key) {
          'inDebugMode' => debug.inDebugMode,
          'debugState' => debugStateLabel(
            debug.service?.state ?? DebugState.inactive,
          ),
          'debuggersAvailable' =>
            debug.service?.registry.hasEnabledDebuggers() ?? false,
          _ => null,
        },
      ),
    );
    add(
      services
          .get<StatusbarService>()
          .addEntry(
            'status.debugging',
            StatusbarAlignment.left,
            priority: debuggingPriority,
            changes: Listenable.merge([debug, KeybindingService.instance]),
            (context) => _debuggingItem(context, debug, host),
          )
          .dispose,
    );
  }
}

/// While a session is debugged, a mark of the debugging colors: the bar
/// on the window's color, not the bar of them upstream's
/// (statusbarColorProvider.ts).
IdeStatusBarItem? _debuggingItem(
  BuildContext context,
  DebugViewService debug,
  WorkbenchHost host,
) {
  final service = debug.service;
  if (service == null || service.state == DebugState.inactive) return null;
  final s = DebugStrings.of(context);
  final background = themeColors['statusBar.debuggingBackground'];
  final foreground = themeColors['statusBar.debuggingForeground'];
  return IdeStatusBarItem(
    service.viewModel.focusedSession?.getLabel() ?? s.runAndDebug,
    icon: Codicons.debugAltSmall,
    color: foreground,
    background: background,
    hoverBackground: Color.alphaBlend(
      foreground.withValues(alpha: 0.12),
      background,
    ),
    tooltip: KeybindingService.instance.titleWithKeybinding(
      s.runAndDebug,
      'workbench.view.debug',
    ),
    onTap: () => host.showView(IdeSideView.debug),
  );
}
