// Finding lldb-dap: the setting, $LLDB_DAP, Xcode's, the PATH (versioned
// names, lldb-vscode) and the macOS fallbacks, over a machine made up of a
// set of files; and the real lookup of a configured path.

import 'dart:io';

import 'package:baocode/debug/adapters/lldb_dap_locator.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:flutter_test/flutter_test.dart';

const _xcode = '/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-dap';
const _commandLineTools =
    '/Library/Developer/CommandLineTools/usr/bin/lldb-dap';
const _brewArm = '/opt/homebrew/opt/llvm/bin/lldb-dap';
const _brewIntel = '/usr/local/opt/llvm/bin/lldb-dap';

/// A machine whose only files are [files]; [folders] are listed in their
/// parents too, but are no files.
final class _Machine {
  _Machine({
    this.environment = const {},
    this.isMacOS = false,
    this.files = const {},
    this.folders = const {},
    this.xcrun,
  });

  final Map<String, String> environment;
  final bool isMacOS;
  final Set<String> files;
  final Set<String> folders;

  /// What `xcrun -f lldb-dap` prints; null when it fails.
  final String? xcrun;

  /// The tools xcrun was asked for.
  final List<String> asked = [];

  /// The folders listed.
  final List<String> listed = [];

  Future<String?> find({String? configured}) => LldbDapSearch(
    environment: environment,
    isMacOS: isMacOS,
    exists: files.contains,
    list: (directory) {
      listed.add(directory);
      final prefix = directory.endsWith('/') ? directory : '$directory/';
      return [
        for (final path in [...files, ...folders])
          if (path.startsWith(prefix) &&
              !path.substring(prefix.length).contains('/'))
            path.substring(prefix.length),
      ];
    },
    xcrun: (tool) async {
      asked.add(tool);
      return xcrun;
    },
  ).find(configured: configured);
}

void main() {
  group('the configured path', () {
    test('is returned when it is a file, before everything else', () async {
      final machine = _Machine(
        isMacOS: true,
        environment: {'LLDB_DAP': '/env/lldb-dap', 'PATH': '/usr/bin'},
        files: {'/my/lldb-dap', '/env/lldb-dap', '/usr/bin/lldb-dap', _xcode},
        xcrun: _xcode,
      );
      expect(await machine.find(configured: '/my/lldb-dap'), '/my/lldb-dap');
      expect(machine.asked, isEmpty);
    });

    test('that is missing gives null, with no fallback', () async {
      final machine = _Machine(
        isMacOS: true,
        environment: {'LLDB_DAP': '/env/lldb-dap', 'PATH': '/usr/bin'},
        files: {'/env/lldb-dap', '/usr/bin/lldb-dap', _xcode},
        xcrun: _xcode,
      );
      expect(await machine.find(configured: '/my/lldb-dap'), isNull);
      expect(machine.asked, isEmpty);
      expect(machine.listed, isEmpty);
    });

    test('has a leading ~/ expanded to the home folder', () async {
      final machine = _Machine(
        environment: {'HOME': '/Users/ada'},
        files: {'/Users/ada/llvm/bin/lldb-dap'},
      );
      expect(
        await machine.find(configured: '~/llvm/bin/lldb-dap'),
        '/Users/ada/llvm/bin/lldb-dap',
      );
      // Only a leading one.
      expect(await machine.find(configured: '/Users/ada/~/lldb-dap'), isNull);
    });

    test('expands ~/ under a home folder written with a slash', () async {
      final machine = _Machine(
        environment: {'HOME': '/Users/ada/'},
        files: {'/Users/ada/lldb-dap'},
      );
      expect(
        await machine.find(configured: '~/lldb-dap'),
        '/Users/ada/lldb-dap',
      );
    });

    test('with ~/ and no home folder known gives null', () async {
      final machine = _Machine(files: {'/Users/ada/lldb-dap'});
      expect(await machine.find(configured: '~/lldb-dap'), isNull);
    });

    test('has the spaces around it dropped', () async {
      final machine = _Machine(files: {'/my/lldb-dap'});
      expect(await machine.find(configured: ' /my/lldb-dap\n'), '/my/lldb-dap');
    });

    test('that is empty or blank is not set: the search goes on', () async {
      final machine = _Machine(
        environment: {'PATH': '/usr/bin'},
        files: {'/usr/bin/lldb-dap'},
      );
      expect(await machine.find(configured: ''), '/usr/bin/lldb-dap');
      expect(await machine.find(configured: '  '), '/usr/bin/lldb-dap');
      expect(await machine.find(), '/usr/bin/lldb-dap');
    });
  });

  group(r'$LLDB_DAP', () {
    test('wins over Xcode, the PATH and the fallbacks', () async {
      final machine = _Machine(
        isMacOS: true,
        environment: {'LLDB_DAP': '/env/lldb-dap', 'PATH': '/usr/bin'},
        files: {'/env/lldb-dap', '/usr/bin/lldb-dap', _xcode, _brewArm},
        xcrun: _xcode,
      );
      expect(await machine.find(), '/env/lldb-dap');
      expect(machine.asked, isEmpty);
    });

    test('naming no file is passed over', () async {
      final machine = _Machine(
        environment: {'LLDB_DAP': '/env/lldb-dap', 'PATH': '/usr/bin'},
        files: {'/usr/bin/lldb-dap'},
      );
      expect(await machine.find(), '/usr/bin/lldb-dap');
    });

    test('set to nothing is passed over', () async {
      final machine = _Machine(
        environment: {'LLDB_DAP': '', 'PATH': '/usr/bin'},
        files: {'/usr/bin/lldb-dap'},
      );
      expect(await machine.find(), '/usr/bin/lldb-dap');
    });
  });

  group('xcrun', () {
    test('is asked for lldb-dap on macOS, and wins over the PATH', () async {
      final machine = _Machine(
        isMacOS: true,
        environment: {'PATH': '/usr/local/bin'},
        files: {_commandLineTools, '/usr/local/bin/lldb-dap'},
        xcrun: '$_commandLineTools\n',
      );
      expect(await machine.find(), _commandLineTools);
      expect(machine.asked, ['lldb-dap']);
    });

    test('failing leaves the PATH', () async {
      final machine = _Machine(
        isMacOS: true,
        environment: {'PATH': '/usr/local/bin'},
        files: {'/usr/local/bin/lldb-dap'},
      );
      expect(await machine.find(), '/usr/local/bin/lldb-dap');
      expect(machine.asked, ['lldb-dap']);
    });

    test('naming no file is passed over', () async {
      final machine = _Machine(
        isMacOS: true,
        environment: {'PATH': '/usr/local/bin'},
        files: {'/usr/local/bin/lldb-dap'},
        xcrun: '/gone/lldb-dap',
      );
      expect(await machine.find(), '/usr/local/bin/lldb-dap');
    });

    test('is not asked off macOS', () async {
      final machine = _Machine(
        environment: {'PATH': '/usr/bin'},
        files: {_xcode, '/usr/bin/lldb-dap'},
        xcrun: _xcode,
      );
      expect(await machine.find(), '/usr/bin/lldb-dap');
      expect(machine.asked, isEmpty);
    });
  });

  group('the PATH', () {
    test('is searched in order', () async {
      final machine = _Machine(
        environment: {'PATH': '/none:/opt/llvm/bin:/usr/bin'},
        files: {'/usr/bin/lldb-dap', '/opt/llvm/bin/lldb-dap'},
      );
      expect(await machine.find(), '/opt/llvm/bin/lldb-dap');
    });

    test('gives lldb-dap before a versioned one beside it', () async {
      final machine = _Machine(
        environment: {'PATH': '/usr/bin'},
        files: {'/usr/bin/lldb-dap-19', '/usr/bin/lldb-dap'},
      );
      expect(await machine.find(), '/usr/bin/lldb-dap');
    });

    test('gives the highest version, by number', () async {
      final machine = _Machine(
        environment: {'PATH': '/usr/bin'},
        files: {
          '/usr/bin/lldb-dap-9',
          '/usr/bin/lldb-dap-18',
          '/usr/bin/lldb-dap-17',
        },
      );
      expect(await machine.find(), '/usr/bin/lldb-dap-18');
    });

    test('takes only lldb-dap-<N> for a versioned name', () async {
      final machine = _Machine(
        environment: {'PATH': '/usr/bin'},
        files: {
          '/usr/bin/lldb-dap-18',
          '/usr/bin/lldb-dap-20.1',
          '/usr/bin/lldb-dap-21-server',
          '/usr/bin/lldb-dap-next',
          '/usr/bin/xlldb-dap-22',
        },
      );
      expect(await machine.find(), '/usr/bin/lldb-dap-18');
    });

    test('passes over a versioned name that is no file', () async {
      final machine = _Machine(
        environment: {'PATH': '/usr/bin'},
        files: {'/usr/bin/lldb-dap-17'},
        folders: {'/usr/bin/lldb-dap-18'},
      );
      expect(await machine.find(), '/usr/bin/lldb-dap-17');
    });

    test('gives a versioned one in an earlier folder before lldb-dap in a '
        'later one', () async {
      final machine = _Machine(
        environment: {'PATH': '/usr/bin:/usr/local/bin'},
        files: {'/usr/bin/lldb-dap-18', '/usr/local/bin/lldb-dap'},
      );
      expect(await machine.find(), '/usr/bin/lldb-dap-18');
    });

    test('gives lldb-vscode when there is no lldb-dap', () async {
      final machine = _Machine(
        environment: {'PATH': '/usr/bin:/usr/local/bin'},
        files: {'/usr/local/bin/lldb-vscode', '/usr/local/bin/lldb-vscode-14'},
      );
      expect(await machine.find(), '/usr/local/bin/lldb-vscode');
    });

    test('gives the highest versioned lldb-vscode', () async {
      final machine = _Machine(
        environment: {'PATH': '/usr/bin'},
        files: {'/usr/bin/lldb-vscode-9', '/usr/bin/lldb-vscode-14'},
      );
      expect(await machine.find(), '/usr/bin/lldb-vscode-14');
    });

    test('gives any lldb-dap before any lldb-vscode', () async {
      final machine = _Machine(
        environment: {'PATH': '/usr/bin:/usr/local/bin:/opt/bin'},
        files: {
          '/usr/bin/lldb-vscode',
          '/usr/local/bin/lldb-vscode-17',
          '/opt/bin/lldb-dap-18',
        },
      );
      expect(await machine.find(), '/opt/bin/lldb-dap-18');
    });

    test('has its empty and relative entries passed over', () async {
      final machine = _Machine(
        environment: {'PATH': ':bin:.:/usr/bin/:'},
        files: {'bin/lldb-dap', './lldb-dap', '/lldb-dap', '/usr/bin/lldb-dap'},
      );
      expect(await machine.find(), '/usr/bin/lldb-dap');
    });

    test('lists a folder once', () async {
      final machine = _Machine(environment: {'PATH': '/usr/bin:/bin'});
      expect(await machine.find(), isNull);
      expect(machine.listed, ['/usr/bin', '/bin']);
    });

    test('wins over the macOS fallbacks', () async {
      final machine = _Machine(
        isMacOS: true,
        environment: {'PATH': '/usr/local/bin'},
        files: {'/usr/local/bin/lldb-vscode', _xcode},
      );
      expect(await machine.find(), '/usr/local/bin/lldb-vscode');
    });

    test('empty or missing finds nothing', () async {
      const files = {'/usr/bin/lldb-dap', '/lldb-dap', 'lldb-dap'};
      expect(await _Machine(files: files).find(), isNull);
      expect(
        await _Machine(environment: {'PATH': ''}, files: files).find(),
        isNull,
      );
    });
  });

  group('the macOS fallbacks', () {
    test('are tried in order', () async {
      final files = {_xcode, _commandLineTools, _brewArm, _brewIntel};
      for (final expected in [
        _xcode,
        _commandLineTools,
        _brewArm,
        _brewIntel,
      ]) {
        final machine = _Machine(isMacOS: true, files: {...files});
        expect(await machine.find(), expected);
        files.remove(expected);
      }
      expect(await _Machine(isMacOS: true).find(), isNull);
    });

    test('are found without a PATH', () async {
      final machine = _Machine(
        isMacOS: true,
        environment: {'PATH': ''},
        files: {_brewArm},
      );
      expect(await machine.find(), _brewArm);
    });

    test('are not tried off macOS', () async {
      final machine = _Machine(
        environment: {'PATH': '/usr/bin'},
        files: {_xcode, _commandLineTools, _brewArm, _brewIntel},
      );
      expect(await machine.find(), isNull);
    });
  });

  group('locateLldbDap', () {
    late Directory dir;

    setUp(() async {
      // Not the login shell's: asking it takes a while.
      ClaudeEnvironment.use(Platform.environment);
      dir = await Directory.systemTemp.createTemp('baocode-lldb-dap-locator-');
    });

    tearDown(() async {
      ClaudeEnvironment.use(null);
      await dir.delete(recursive: true);
    });

    test('gives the configured path when a file is there', () async {
      final file = File('${dir.path}/lldb-dap');
      await file.writeAsString('');
      expect(await locateLldbDap(configured: file.path), file.path);
    });

    test('gives null for a configured path with no file', () async {
      expect(await locateLldbDap(configured: '${dir.path}/lldb-dap'), isNull);
      // A folder is no debugger.
      expect(await locateLldbDap(configured: dir.path), isNull);
    });
  });
}
