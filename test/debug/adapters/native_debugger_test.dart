// BaoCode's own debuggers on a debug service's registry: LLDB's
// contribution, its adapter looked for as a session starts, and what is
// said when there is none.

import 'dart:async';

import 'package:baocode/base/cancellation.dart';
import 'package:baocode/base/uri.dart' show VsUri;
import 'package:baocode/debug/adapters/lldb_dap.dart';
import 'package:baocode/debug/adapters/native_debugger.dart';
import 'package:baocode/debug/common/debug_storage.dart';
import 'package:baocode/debug/common/debug_types.dart';
import 'package:baocode/debug/common/debug_utils.dart';
import 'package:baocode/debug/service/debug_configuration_manager.dart';
import 'package:baocode/debug/service/debug_host.dart';
import 'package:baocode/debug/service/debug_service.dart';
import 'package:baocode/debug/session/debug_adapter.dart';
import 'package:baocode/debug/session/debug_session.dart';
import 'package:baocode/debug/session/stream_debug_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_debug_adapter.dart';

class _Host extends FakeDebugHost {
  _Host({this.os = DebugTargetOs.macintosh, this.language = 'en'});

  final DebugTargetOs os;
  final String language;
  DebuggersUnavailable? unavailable;

  @override
  DebugTargetOs get targetOs => os;

  @override
  String get locale => language;

  @override
  DebuggersUnavailable? get debuggersUnavailable => unavailable;
}

Future<DebugService> _service(
  _Host host, {
  List<NativeDebugger>? debuggers,
  RunInTerminal? runInTerminal,
  OpenDebugTerminal? openTerminal,
}) async {
  final service = DebugService(
    host: host,
    storage: MemoryDebugStorageBackend(),
    fileStore: MemoryLaunchFileStore(),
  );
  addTearDown(service.dispose);
  registerNativeDebuggers(
    service,
    debuggers ?? const [LldbDapDebugger()],
    runInTerminal: runInTerminal,
    openTerminal: openTerminal,
  );
  await service.configurationManager.initialize();
  return service;
}

void main() {
  group('LLDB on the registry', () {
    test('is the debugger of C and C++, which take breakpoints', () async {
      final service = await _service(_Host());
      final lldb = service.registry.getDebugger(lldbDapType);
      expect(lldb, isNotNull);
      expect(lldb!.label, 'LLDB');
      expect(lldb.interestedInLanguage('c'), isTrue);
      expect(lldb.interestedInLanguage('cpp'), isTrue);
      expect(lldb.interestedInLanguage('python'), isFalse);
      expect(service.registry.hasEnabledDebuggers(), isTrue);
      expect(service.registry.canSetBreakpointsIn('cpp'), isTrue);
      expect(service.registry.canSetBreakpointsIn('python'), isFalse);
    });

    test('starts a launch.json with a launch and an attach', () async {
      final service = await _service(_Host());
      final content = service.registry
          .getDebugger(lldbDapType)!
          .getInitialConfigurationContent();
      expect(content, contains('"request": "launch"'));
      expect(content, contains(r'"program": "${workspaceFolder}/'));
      expect(content, contains('"request": "attach"'));
      expect(content, contains(r'"pid": "${command:pickProcess}"'));
    });

    test('maps pickProcess to its command', () async {
      final service = await _service(_Host());
      expect(service.registry.getDebugger(lldbDapType)!.variables, {
        'pickProcess': pickProcessCommand,
      });
    });

    test('a picked pid goes to the adapter as a number', () async {
      final service = await _service(_Host());
      Future<Object?> resolved(Json config) => service.configurationManager
          .resolveDebugConfigurationWithSubstitutedVariables(
            null,
            lldbDapType,
            config,
            CancellationTokenSource().token,
          );
      expect(
        await resolved({'type': lldbDapType, 'request': 'attach', 'pid': '42'}),
        {'type': lldbDapType, 'request': 'attach', 'pid': 42},
      );
      // Already one, or none: as it is.
      expect(await resolved({'type': lldbDapType, 'pid': 7}), {
        'type': lldbDapType,
        'pid': 7,
      });
      expect(await resolved({'type': lldbDapType, 'program': '/a'}), {
        'type': lldbDapType,
        'program': '/a',
      });
    });

    test('what the adapter runs in a terminal goes to the IDE', () async {
      final asked = <(Json, String)>[];
      final service = await _service(
        _Host(),
        runInTerminal: (args, sessionId) async {
          asked.add((args, sessionId));
          return 9;
        },
      );
      final pid = await service.registry.runInTerminal(lldbDapType, {
        'args': ['/bin/echo'],
      }, 'session');
      expect(pid, 9);
      expect(asked.single.$1, {
        'args': ['/bin/echo'],
      });
      expect(asked.single.$2, 'session');
    });
  });

  group('lldb-dap looked for', () {
    Future<DebugAdapterTransport> open(
      _Host host,
      Future<String?> Function({String? configured}) locate,
    ) async {
      final debugger = LldbDapDebugger(
        locate: locate,
        environment: () async => const {'PATH': '/usr/bin'},
      );
      final service = await _service(host, debuggers: [debugger]);
      final session = await _session(service);
      return debugger.open(session, host);
    }

    test('found: a process on its stdio, in the login environment', () async {
      String? asked = 'unset';
      final transport = await open(_Host(), ({configured}) async {
        asked = configured;
        return '/tools/lldb-dap';
      });
      expect(asked, isNull);
      expect(transport, isA<StdioDebugAdapterTransport>());
      final stdio = transport as StdioDebugAdapterTransport;
      expect(stdio.executable, '/tools/lldb-dap');
      expect(stdio.arguments, isEmpty);
      expect(stdio.environment, {'PATH': '/usr/bin'});
      expect(stdio.workingDirectory, '/work/app');
    });

    test('the path set in settings.json is the one asked for', () async {
      final host = _Host()
        ..settingValues[lldbDapPathSetting] = '  /opt/lldb-dap ';
      String? asked;
      await open(host, ({configured}) async {
        asked = configured;
        return configured;
      });
      expect(asked, '/opt/lldb-dap');
    });

    test('not found on macOS: how to install it there', () async {
      await expectLater(
        open(_Host(), ({configured}) async => null),
        throwsA(
          isA<DebugAdapterUnavailable>().having(
            (e) => '$e',
            'message',
            allOf(contains('xcode-select --install'), contains('lldbDap.path')),
          ),
        ),
      );
    });

    test('not found on Linux: the distribution\'s package', () async {
      await expectLater(
        open(_Host(os: DebugTargetOs.linux), ({configured}) async => null),
        throwsA(
          isA<DebugAdapterUnavailable>().having(
            (e) => '$e',
            'message',
            contains('apt install lldb'),
          ),
        ),
      );
    });

    test('a path set that is not there is named, in the language', () async {
      final host = _Host(language: 'zh')
        ..settingValues[lldbDapPathSetting] = '/nowhere/lldb-dap';
      await expectLater(
        open(host, ({configured}) async => null),
        throwsA(
          isA<DebugAdapterUnavailable>().having(
            (e) => '$e',
            'message',
            allOf(contains('/nowhere/lldb-dap'), contains('不存在')),
          ),
        ),
      );
    });

    test('a start without it shows the way to get it', () async {
      final host = _Host();
      final service = await _service(
        host,
        debuggers: [LldbDapDebugger(locate: ({configured}) async => null)],
      );
      final started = await service.startDebugging(null, {
        'type': lldbDapType,
        'request': 'launch',
        'name': 'Debug',
        'program': '/work/app/a.out',
      });
      expect(started, isFalse);
      expect(host.errors.single, contains('lldb-dap was not found'));
      expect(service.model.getSessions(), isEmpty);
    });
  });

  group('a program in a terminal', () {
    const launch = <String, Object?>{
      'type': lldbDapType,
      'request': 'launch',
      'name': 'Debug',
      'program': '/work/app/a.out',
      'cwd': '/work/app',
      'runInTerminal': true,
    };

    /// Opens terminals on [tty], and tells of each asked for and closed.
    OpenDebugTerminal opener(List<String> log, {String? tty = '/dev/ttys9'}) =>
        ({title, cwd}) async {
          log.add('open $title in $cwd');
          return tty == null
              ? null
              : DebugTerminal(tty: tty, close: () => log.add('close $tty'));
        };

    Future<Json> resolved(
      _Host host,
      Json config, {
      OpenDebugTerminal? openTerminal,
    }) => const LldbDapDebugger().resolve(
      config,
      host,
      openTerminal: openTerminal,
    );

    test('on macOS LLDB starts it, on a terminal of the IDE\'s', () async {
      final log = <String>[];
      final config = await resolved(_Host(), {
        ...launch,
        'initCommands': ['settings set target.x86-disassembly-flavor intel'],
      }, openTerminal: opener(log));
      expect(log, ['open Debug in /work/app']);
      // lldb-dap is not asked for one: it cannot attach to its own copy.
      expect(config['runInTerminal'], isFalse);
      expect(config['initCommands'], [
        'settings set target.input-path /dev/ttys9',
        'settings set target.output-path /dev/ttys9',
        'settings set target.error-path /dev/ttys9',
        // The user's own come after, and may say otherwise.
        'settings set target.x86-disassembly-flavor intel',
      ]);
      expect(config[debugTerminalKey], '/dev/ttys9');
      expect(config['program'], '/work/app/a.out');
    });

    test('asked for as lldb-dap 21 has it, by its console', () async {
      final log = <String>[];
      final config = await resolved(_Host(), {
        ...launch,
        'runInTerminal': null,
        'console': 'integratedTerminal',
      }, openTerminal: opener(log));
      expect(log, hasLength(1));
      expect(config['console'], 'internalConsole');
      expect(config[debugTerminalKey], '/dev/ttys9');
    });

    test('on Linux lldb-dap runs it in the terminal itself', () async {
      final log = <String>[];
      final config = await resolved(
        _Host(os: DebugTargetOs.linux),
        launch,
        openTerminal: opener(log),
      );
      expect(log, isEmpty);
      expect(config, launch);
    });

    test('not asked for, attached to, or no terminal: as written', () async {
      final log = <String>[];
      final open = opener(log);
      final plain = {...launch, 'runInTerminal': false};
      expect(await resolved(_Host(), plain, openTerminal: open), plain);
      final attach = {...launch, 'request': 'attach'};
      expect(await resolved(_Host(), attach, openTerminal: open), attach);
      expect(log, isEmpty);
      // No terminals in the IDE.
      expect(await resolved(_Host(), launch), launch);
      // One that did not open.
      expect(
        await resolved(_Host(), launch, openTerminal: opener(log, tty: null)),
        launch,
      );
    });

    test('the terminal is closed as its session ends', () async {
      final log = <String>[];
      final host = _Host();
      final service = await _service(host, openTerminal: opener(log));
      final session = await _session(service, config: launch);
      expect(session.configuration[debugTerminalKey], '/dev/ttys9');
      expect(log, ['open Debug in /work/app']);
      await service.stopSession(session);
      await until(() => service.model.getSessions().isEmpty);
      expect(log, ['open Debug in /work/app', 'close /dev/ttys9']);
    });
  });

  group('DeferredDebugAdapterTransport', () {
    test('carries the messages of the adapter it opened', () async {
      final inner = FakeDebugAdapter();
      final transport = DeferredDebugAdapterTransport(() async => inner);
      addTearDown(transport.dispose);
      final received = <Json>[];
      final exits = <int?>[];
      transport
        ..onMessage(received.add)
        ..onExit(exits.add);
      // Nothing to send to yet: dropped, not thrown.
      transport.send({'type': 'request', 'seq': 1, 'command': 'initialize'});
      await transport.start();
      inner.acceptMessage({'type': 'event', 'event': 'initialized'});
      inner.fireExit(3);
      expect(received, [
        {'type': 'event', 'event': 'initialized'},
      ]);
      expect(exits, [3]);
    });

    test('throws from its start what the adapter was not found for', () {
      final transport = DeferredDebugAdapterTransport(
        () async => throw const DebugAdapterUnavailable('none here'),
      );
      addTearDown(transport.dispose);
      expect(
        transport.start(),
        throwsA(
          isA<DebugAdapterUnavailable>().having(
            (e) => e.message,
            'message',
            'none here',
          ),
        ),
      );
    });

    test('disposed while looking: the adapter found is not started', () async {
      final found = Completer<DebugAdapterTransport>();
      final inner = _CountingTransport();
      final transport = DeferredDebugAdapterTransport(() => found.future);
      final start = transport.start();
      transport.dispose();
      found.complete(inner);
      await start;
      expect(inner.started, 0);
      expect(inner.disposed, 1);
    });
  });

  group('a language without a debugger', () {
    test('is told so, with no marketplace to look in', () async {
      final host = _Host()
        ..editor = DebugActiveEditor(
          uri: VsUri.file('/work/app/main.py'),
          languageId: 'python',
        );
      final service = await _service(host);
      expect(await service.registry.guessDebugger(false), isNull);
      expect(host.notifications, ['BaoCode cannot debug python yet.']);
    });

    test('in a remote project, that is the reason given', () async {
      final host = _Host()
        ..unavailable = DebuggersUnavailable.remote
        ..editor = DebugActiveEditor(
          uri: VsUri.file('/work/app/main.cc'),
          languageId: 'cpp',
        );
      final service = DebugService(
        host: host,
        storage: MemoryDebugStorageBackend(),
        fileStore: MemoryLaunchFileStore(),
      );
      addTearDown(service.dispose);
      await service.configurationManager.initialize();
      expect(await service.registry.guessDebugger(false), isNull);
      expect(host.notifications, [
        'Debugging is not available in remote projects yet.',
      ]);
    });
  });
}

/// A session of [service]'s in its folder, started on a scripted adapter:
/// what a debugger is asked to open an adapter for.
Future<DebugSession> _session(DebugService service, {Json? config}) async {
  late DebugSession made;
  service.registry.registerDebugAdapterFactory(
    [lldbDapType],
    FakeAdapterFactory((session) {
      made = session;
      return FakeDebugAdapter();
    }),
  );
  await service.startDebugging(
    service.configurationManager.getLaunches().first,
    config ??
        {
          'type': lldbDapType,
          'request': 'launch',
          'name': 'Debug',
          'program': '/work/app/a.out',
        },
  );
  return made;
}

/// A transport that counts what is asked of it.
class _CountingTransport extends EmitterDebugAdapterTransport {
  int started = 0;
  int disposed = 0;

  @override
  Future<void> start() async => started++;

  @override
  void send(Json message) {}

  @override
  Future<void> stop() async {}

  @override
  void dispose() {
    disposed++;
    super.dispose();
  }
}
