import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/client.dart';
import 'package:baocode/remote/remote_binaries.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late String remote;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('remote_binaries_test');
    remote = p.join(temp.path, 'remote');
    Directory(remote).createSync();
    File(p.join(remote, 'VERSION')).writeAsStringSync('1.0.0.1-abc\n');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  RemoteServerBinaries? found() => bundledServerBinaries(
    environment: {'BAOCODE_REMOTE_SERVER_DIR': remote},
    executable: p.join(temp.path, 'app', 'baocode'),
    current: temp.path,
  );

  test('the builds in the folder, when they are there', () async {
    File(p.join(remote, 'baocode-server-linux-x64')).writeAsStringSync('raw');
    File(p.join(remote, 'baocode-server-linux-riscv64'))
        .writeAsStringSync('riscv');
    final binaries = found();
    expect(binaries, isA<DirectoryServerBinaries>());
    expect(binaries!.version, '1.0.0.1-abc');
    expect(utf8.decode((await binaries.read('linux-x64'))!), 'raw');
    expect(utf8.decode((await binaries.read('linux-riscv64'))!), 'riscv');
  });

  test('the macOS builds in the folder', () async {
    File(p.join(remote, 'baocode-server-darwin-arm64'))
        .writeAsStringSync('mac');
    final binaries = found()!;
    expect(binaries, isA<DirectoryServerBinaries>());
    expect(utf8.decode((await binaries.read('darwin-arm64'))!), 'mac');
    expect(await binaries.read('linux-x64'), isNull);
  });

  // docs/egress-policy.md: a server is carried, never downloaded.
  test('none where there is only a list of downloads', () {
    File(p.join(remote, 'servers.json')).writeAsStringSync(
      jsonEncode({
        'version': '1.0.0.1-abc',
        'files': {
          'linux-x64': {
            'url': 'https://example.com/baocode-server-linux-x64.gz',
            'size': 1,
            'sha256': '00',
          },
        },
      }),
    );
    expect(found(), isNull);
  });
}
