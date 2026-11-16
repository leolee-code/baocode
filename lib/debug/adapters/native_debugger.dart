// BaoCode's own debuggers: the debug types the app serves itself, where VS
// Code leaves them to extensions. Each says what an extension's
// `contributes.debuggers` would, and starts its adapter on this machine;
// [registerNativeDebuggers] puts them on a debug service's registry, as the
// extension host's `$registerDebugTypes` would.
//
// No upstream: there the adapters are the extensions'
// (`registerDebugAdapterDescriptorFactory`).

import 'dart:async';

import '../../base/cancellation.dart';
import '../../base/uri.dart' show VsUri;
import '../common/debug_types.dart';
import '../service/debug_configuration_manager.dart';
import '../service/debug_host.dart';
import '../service/debug_service.dart';
import '../service/debugger.dart';
import '../session/debug_adapter.dart';
import '../session/debug_session.dart';

/// A debugger of BaoCode's own: a debug type, and its adapter.
abstract class NativeDebugger {
  const NativeDebugger();

  /// Its debug type (launch.json's `type`).
  String get type;

  /// What an extension would contribute for it: the debugger (its label,
  /// languages and initial configurations) and the languages that take
  /// breakpoints.
  DebuggerExtension get extension;

  /// A transport to a new adapter for [session], not started. Throws a
  /// [DebugAdapterUnavailable] when the adapter is not on this machine.
  Future<DebugAdapterTransport> open(
    DebugSession session,
    DebugServiceHost host,
  );

  /// [config] as the adapter takes it, its variables substituted. A
  /// program that is to run in a terminal the adapter cannot start one in
  /// gets [openTerminal]'s (see [DebugTerminal]).
  Future<Json> resolve(
    Json config,
    DebugServiceHost host, {
    OpenDebugTerminal? openTerminal,
  }) async => config;
}

/// A terminal of the IDE's that a program's input and output are given
/// to, by a debugger that starts the program itself.
final class DebugTerminal {
  const DebugTerminal({required this.tty, required this.close});

  /// Its device (`/dev/ttys004`).
  final String tty;

  /// Ends what keeps it open: the session it was for is over.
  final void Function() close;
}

/// Opens a [DebugTerminal], named [title], in [cwd]; null where there is
/// none to open.
typedef OpenDebugTerminal = Future<DebugTerminal?> Function({
  String? title,
  String? cwd,
});

/// The key, in a configuration resolved, of the device of the
/// [DebugTerminal] opened for it: the terminal is closed as its session
/// ends. With the `__` of the keys adapters pass over.
const debugTerminalKey = '__debugTerminal';

/// A debugger's adapter is not on this machine; [message] says how to get
/// it, for the user.
final class DebugAdapterUnavailable implements Exception {
  const DebugAdapterUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// `runInTerminal`, as the IDE does it: the process id, if known.
typedef RunInTerminal = Future<int?> Function(Json args, String sessionId);

/// Puts [debuggers] on [service]'s registry: their contributions, a
/// factory for their adapters, and their [NativeDebugger.resolve]. What an
/// adapter asks to run in a terminal goes to [runInTerminal], else to the
/// service's host; a debugger that starts the program itself gets its
/// terminal from [openTerminal], closed as the session ends.
void registerNativeDebuggers(
  DebugService service,
  List<NativeDebugger> debuggers, {
  RunInTerminal? runInTerminal,
  OpenDebugTerminal? openTerminal,
}) {
  final registry = service.registry;
  // The terminals opened, by device, till their sessions end.
  final terminals = <String, DebugTerminal>{};
  final OpenDebugTerminal? opening = openTerminal == null
      ? null
      : ({title, cwd}) async {
          final terminal = await openTerminal(title: title, cwd: cwd);
          if (terminal != null) terminals[terminal.tty] = terminal;
          return terminal;
        };
  service.onDidEndSession((ended) {
    // Restarted as it was configured, the session goes on in it.
    if (ended.restart) return;
    final tty = ended.session.configuration.str(debugTerminalKey);
    terminals.remove(tty)?.close();
  });
  registry.setExtensions([for (final d in debuggers) d.extension]);
  for (final debugger in debuggers) {
    registry.registerDebugAdapterFactory(
      [debugger.type],
      _NativeAdapterFactory(
        debugger,
        service.host,
        runInTerminal ?? service.host.runInTerminal,
      ),
    );
    service.configurationManager.providers.register(
      DebugConfigurationProvider(
        type: debugger.type,
        resolveDebugConfigurationWithSubstitutedVariables: (
          VsUri? folder,
          Json config,
          CancellationToken token,
        ) => debugger.resolve(config, service.host, openTerminal: opening),
      ),
    );
  }
}

/// Makes [debugger]'s adapters (`IDebugAdapterFactory`).
final class _NativeAdapterFactory implements DebugAdapterFactory {
  _NativeAdapterFactory(this.debugger, this.host, this._runInTerminal);

  final NativeDebugger debugger;
  final DebugServiceHost host;
  final RunInTerminal _runInTerminal;

  @override
  DebugAdapterTransport createDebugAdapter(DebugSession session) =>
      DeferredDebugAdapterTransport(() => debugger.open(session, host));

  /// The debug service resolves the variables there are.
  @override
  Future<Json> substituteVariables(
    DebugWorkspaceFolder? folder,
    Json config,
  ) async => config;

  @override
  Future<int?> runInTerminal(Json args, String sessionId) =>
      _runInTerminal(args, sessionId);
}

/// A transport to an adapter looked for only as it starts: a factory makes
/// its transport at once ([DebugAdapterFactory.createDebugAdapter]), and
/// finding the adapter takes a while.
final class DeferredDebugAdapterTransport extends EmitterDebugAdapterTransport {
  DeferredDebugAdapterTransport(this._open);

  final Future<DebugAdapterTransport> Function() _open;
  DebugAdapterTransport? _inner;
  bool _disposed = false;

  /// Throws what the adapter was not found for.
  @override
  Future<void> start() async {
    final inner = await _open();
    if (_disposed) {
      inner.dispose();
      return;
    }
    _inner = inner
      ..onMessage(acceptMessage)
      ..onError(fireError)
      ..onExit(fireExit);
    await inner.start();
  }

  @override
  void send(Json message) => _inner?.send(message);

  @override
  Future<void> stop() async => _inner?.stop();

  @override
  void dispose() {
    _disposed = true;
    _inner?.dispose();
    _inner = null;
    super.dispose();
  }
}
