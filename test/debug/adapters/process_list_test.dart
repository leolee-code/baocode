// The attach picker's processes: reading `ps`'s lines (macOS's and
// Linux's), the executable's name out of a command line, the order, and
// the real list.

import 'dart:io';

import 'package:baocode/debug/adapters/process_list.dart';
import 'package:flutter_test/flutter_test.dart';

// As `ps x -ww -o pid= -o etime= -o args=` prints on macOS.
const _macOS = r'''
  419 01-19:03:49 /usr/sbin/distnoted agent
  424 01-19:03:49 /usr/libexec/UserEventAgent (Aqua)
 2707    02:17:14 -zsh
 5120       12:34 /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Renderer).app/Contents/MacOS/Code Helper (Renderer) --type=renderer --user-data-dir=/Users/ada/Library/Application Support/Code
 7356       00:01 /usr/bin/python3 -c import time\012time.sleep(3) tab\011x
 7351       00:00 <defunct>
''';

// As procps prints on Linux.
const _linux = r'''
   1234  1-02:03:04 /usr/lib/systemd/systemd --user
   2001    10:20:30 /usr/bin/python3 /home/ada/my scripts/serve.py --port 8000
  31002       05:06 ./build/app --verbose
  31010       00:07 nginx: worker process
  31011       00:01 [sh] <defunct>
4194304       00:00 [kworker/0:1-events]
''';

typedef _Row = (int pid, String name, Duration? elapsed, String command);

List<_Row> _rows(List<DebugProcess> processes) => [
  for (final process in processes)
    (process.pid, process.name, process.elapsed, process.command),
];

String _name(String command, {Set<String>? files}) =>
    parsePsOutput('  1 00:01 $command\n', isFile: files?.contains).single.name;

void main() {
  group('parsePsOutput', () {
    test('reads macOS lines', () {
      expect(_rows(parsePsOutput(_macOS)), [
        (
          419,
          'distnoted',
          const Duration(days: 1, hours: 19, minutes: 3, seconds: 49),
          '/usr/sbin/distnoted agent',
        ),
        (
          424,
          'UserEventAgent',
          const Duration(days: 1, hours: 19, minutes: 3, seconds: 49),
          '/usr/libexec/UserEventAgent (Aqua)',
        ),
        (
          2707,
          'zsh',
          const Duration(hours: 2, minutes: 17, seconds: 14),
          '-zsh',
        ),
        (
          5120,
          'Visual',
          const Duration(minutes: 12, seconds: 34),
          '/Applications/Visual Studio Code.app/Contents/Frameworks/'
              'Code Helper (Renderer).app/Contents/MacOS/'
              'Code Helper (Renderer) --type=renderer '
              '--user-data-dir=/Users/ada/Library/Application Support/Code',
        ),
        (
          7356,
          'python3',
          const Duration(seconds: 1),
          r'/usr/bin/python3 -c import time\012time.sleep(3) tab\011x',
        ),
        (7351, '<defunct>', Duration.zero, '<defunct>'),
      ]);
    });

    test('reads Linux lines', () {
      expect(_rows(parsePsOutput(_linux)), [
        (
          1234,
          'systemd',
          const Duration(days: 1, hours: 2, minutes: 3, seconds: 4),
          '/usr/lib/systemd/systemd --user',
        ),
        (
          2001,
          'python3',
          const Duration(hours: 10, minutes: 20, seconds: 30),
          '/usr/bin/python3 /home/ada/my scripts/serve.py --port 8000',
        ),
        (
          31002,
          'app',
          const Duration(minutes: 5, seconds: 6),
          './build/app --verbose',
        ),
        (31010, 'nginx', const Duration(seconds: 7), 'nginx: worker process'),
        (31011, '[sh]', const Duration(seconds: 1), '[sh] <defunct>'),
        (
          4194304,
          '[kworker/0:1-events]',
          Duration.zero,
          '[kworker/0:1-events]',
        ),
      ]);
    });

    test('reads the forms of the elapsed time', () {
      Duration? elapsed(String etime) =>
          parsePsOutput('7 $etime app').single.elapsed;

      expect(elapsed('00:00'), Duration.zero);
      expect(elapsed('00:07'), const Duration(seconds: 7));
      expect(elapsed('12:34'), const Duration(minutes: 12, seconds: 34));
      expect(
        elapsed('01:02:03'),
        const Duration(hours: 1, minutes: 2, seconds: 3),
      );
      expect(
        elapsed('1-02:03:04'),
        const Duration(days: 1, hours: 2, minutes: 3, seconds: 4),
      );
      expect(elapsed('02-00:00:00'), const Duration(days: 2));
      expect(
        elapsed('1234-23:59:59'),
        const Duration(days: 1234, hours: 23, minutes: 59, seconds: 59),
      );
    });

    test('keeps a process whose age ps gave as -', () {
      final process = parsePsOutput('  12 - /bin/cat').single;
      expect(process.pid, 12);
      expect(process.elapsed, isNull);
      expect(process.command, '/bin/cat');
    });

    test('reads a pid with and without spaces before it', () {
      expect(
        [
          for (final process in parsePsOutput(
            '7 00:01 a\n   8 00:01 b\n\t9 00:01 c\n99999 00:01 d',
          ))
            process.pid,
        ],
        [7, 8, 9, 99999],
      );
    });

    test('keeps the spaces inside a command, not those around it', () {
      final process = parsePsOutput('  7   00:01   sh -c  echo   hi  \n')
          .single;
      expect(process.command, 'sh -c  echo   hi');
      expect(process.name, 'sh');
    });

    test('skips the lines that are no process', () {
      expect(
        _rows(
          parsePsOutput(
            [
              '',
              '   ',
              '  PID     ELAPSED COMMAND',
              'ps: illegal option -- q',
              'abc 00:01 /bin/cat',
              '-5 00:01 /bin/cat',
              '12x 00:01 /bin/cat',
              '  12 00:01',
              '  12 00:01   ',
              '  12 /bin/cat',
              '  12 1:2:3:4 /bin/cat',
              '  12 1-02 /bin/cat',
              '  12 12 /bin/cat',
              '  12 ab:cd /bin/cat',
              '  12 99999999999999999999:00 /bin/cat',
              '  13 00:02 /bin/echo kept',
              'time.sleep(3)',
            ].join('\n'),
          ),
        ),
        [(13, 'echo', const Duration(seconds: 2), '/bin/echo kept')],
      );
    });

    test('reads nothing out of nothing', () {
      expect(parsePsOutput(''), isEmpty);
      expect(parsePsOutput('\n\n'), isEmpty);
    });
  });

  group('the name', () {
    test('is the base name of the first word', () {
      expect(_name('/bin/cat /etc/hosts'), 'cat');
      expect(_name('/bin/cat'), 'cat');
      expect(_name('node server.js'), 'node');
      expect(_name('./build/app --verbose'), 'app');
      expect(_name('../tools/run'), 'run');
    });

    test('is without the dash of a login shell', () {
      expect(_name('-zsh'), 'zsh');
      expect(_name('-bash -l'), 'bash');
      expect(_name('-/bin/zsh'), 'zsh');
    });

    test('is without the colon of a title a daemon gave itself', () {
      expect(_name('nginx: worker process'), 'nginx');
      expect(_name('sshd: ada@pts/0'), 'sshd');
      expect(_name('postgres: checkpointer'), 'postgres');
    });

    test('is what ps shows for a process without arguments', () {
      expect(_name('[kworker/0:1-events]'), '[kworker/0:1-events]');
      expect(_name('[sh] <defunct>'), '[sh]');
      expect(_name('(bash)'), '(bash)');
      expect(_name('<defunct>'), '<defunct>');
    });

    test('is never empty', () {
      expect(_name('/'), '/');
      expect(_name('- x'), '-');
      expect(_name(': x'), ':');
      expect(_name('/tmp/dir/ x'), '/tmp/dir/');
    });

    test('ends at the first space when no file is known', () {
      expect(
        _name('/Applications/Some App.app/Contents/MacOS/Some App --flag'),
        'Some',
      );
    });

    group('with the files known', () {
      test('is the executable whose path has spaces', () {
        expect(
          _name(
            '/Applications/Some App.app/Contents/MacOS/Some App --flag',
            files: {'/Applications/Some App.app/Contents/MacOS/Some App'},
          ),
          'Some App',
        );
        expect(
          _name(
            '/Applications/Visual Studio Code.app/Contents/Frameworks/'
            'Code Helper (Renderer).app/Contents/MacOS/'
            'Code Helper (Renderer) --type=renderer '
            '--user-data-dir=/Users/ada/Library/Application Support/Code',
            files: {
              '/Applications/Visual Studio Code.app/Contents/Frameworks/'
                  'Code Helper (Renderer).app/Contents/MacOS/'
                  'Code Helper (Renderer)',
            },
          ),
          'Code Helper (Renderer)',
        );
      });

      test('is the executable that is the whole command', () {
        expect(
          _name(
            '/Applications/Some App.app/Contents/MacOS/Some App',
            files: {'/Applications/Some App.app/Contents/MacOS/Some App'},
          ),
          'Some App',
        );
      });

      test('is the interpreter, not its script', () {
        expect(
          _name(
            '/usr/bin/python3 /home/ada/my scripts/serve.py --port 8000',
            files: {'/usr/bin/python3', '/home/ada/my scripts/serve.py'},
          ),
          'python3',
        );
      });

      test('is the shortest path that is a file', () {
        expect(
          _name(
            '/opt/tool one two',
            files: {'/opt/tool', '/opt/tool one', '/opt/tool one two'},
          ),
          'tool',
        );
      });

      test('ends at the first space when no stretch is a file', () {
        expect(
          _name('/app/bin/node /app/server.js', files: {'/usr/bin/node'}),
          'node',
        );
        expect(
          _name('/usr/sbin/sshd: ada@pts/0', files: {'/usr/sbin/sshd'}),
          'sshd',
        );
      });

      test('asks only about absolute paths', () {
        final asked = <String>[];
        bool isFile(String path) {
          asked.add(path);
          return true;
        }

        final processes = parsePsOutput(
          '1 00:01 node /srv/app.js\n2 00:01 -zsh\n3 00:01 [sh] <defunct>',
          isFile: isFile,
        );
        expect(
          [for (final process in processes) process.name],
          ['node', 'zsh', '[sh]'],
        );
        expect(asked, isEmpty);
      });
    });
  });

  group('DebugProcess.mostRecentFirst', () {
    DebugProcess process(int pid, [Duration? elapsed]) =>
        DebugProcess(pid: pid, name: 'p', command: 'p', elapsed: elapsed);

    test('puts the most recently started first, the unknown last, and the '
        'higher pid first among those as old', () {
      final sorted = [
        process(10, const Duration(hours: 1)),
        process(11),
        process(12, const Duration(seconds: 5)),
        process(13, const Duration(days: 2)),
        process(14, const Duration(seconds: 5)),
        process(15),
        process(16, Duration.zero),
      ]..sort(DebugProcess.mostRecentFirst);
      expect(
        [for (final process in sorted) process.pid],
        [16, 14, 12, 10, 13, 15, 11],
      );
    });

    test('orders what ps printed', () {
      final sorted = parsePsOutput(_linux)..sort(DebugProcess.mostRecentFirst);
      expect(
        [for (final process in sorted) process.pid],
        [4194304, 31011, 31010, 31002, 2001, 1234],
      );
    });
  });

  group('listDebugProcesses', () {
    test(
      'lists a process just started, not this one nor ps, in order',
      () async {
        final child = await Process.start('sleep', ['30']);
        addTearDown(child.kill);
        final processes = await listDebugProcesses();

        final listed = processes.where((p) => p.pid == child.pid).toList();
        expect(listed, hasLength(1), reason: '$processes');
        expect(listed.single.name, 'sleep');
        expect(listed.single.command, 'sleep 30');
        expect(listed.single.elapsed, lessThan(const Duration(minutes: 1)));

        expect(processes.where((p) => p.pid == pid), isEmpty);
        expect(
          processes.where((p) => p.command.startsWith('ps x -ww -o pid=')),
          isEmpty,
        );
        expect(
          [...processes]..sort(DebugProcess.mostRecentFirst),
          orderedEquals(processes),
        );
      },
      skip: Platform.isWindows ? 'no ps' : false,
    );
  });
}
