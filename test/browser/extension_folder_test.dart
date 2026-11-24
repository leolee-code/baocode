import 'dart:convert';
import 'dart:io';

import 'package:baocode/browser/browser_bridge.dart';
import 'package:baocode/browser/extension_folder.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The extension as the checkout has it: each file's path under
/// browser_extension/, and its bytes.
Map<String, List<int>> _checkout() => {
  for (final entry in Directory('browser_extension').listSync(recursive: true))
    if (entry is File)
      p.relative(entry.path, from: 'browser_extension').replaceAll(r'\', '/'):
          entry.readAsBytesSync(),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('extension_folder'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('writes out the extension the build carries, all of it', () async {
    final folder = p.join(temp.path, 'browser-extension');
    // Left from an older one: gone.
    File(p.join(folder, 'old.js'))
      ..createSync(recursive: true)
      ..writeAsStringSync('old');

    expect(await ExtensionFolder.prepare(folder: folder), folder);

    final written = {
      for (final entry in Directory(folder).listSync(recursive: true))
        if (entry is File)
          p.relative(entry.path, from: folder).replaceAll(r'\', '/'): entry
              .readAsBytesSync(),
    };
    final checkout = _checkout();
    expect(written.keys.toSet(), checkout.keys.toSet());
    for (final MapEntry(:key, :value) in checkout.entries) {
      expect(written[key], value, reason: key);
    }
  });

  test('its key gives it the id the browsers\' host lets in', () {
    final manifest = jsonDecode(
      File('browser_extension/manifest.json').readAsStringSync(),
    ) as Map<String, Object?>;
    // Chrome's id of an unpacked extension with a key: the SHA-256 of the
    // key's bytes, its first 16 bytes in hex, written with a-p.
    final digest = sha256.convert(base64.decode(manifest['key']! as String));
    final id = [
      for (final byte in digest.bytes.take(16)) ...[byte >> 4, byte & 0xf],
    ].map((nibble) => String.fromCharCode(0x61 + nibble)).join();
    expect(BrowserBridge.extensionIds, contains(id));
  });

  test('a build without it says so', () async {
    final bundle = _NoExtension();
    expect(
      ExtensionFolder.prepare(bundle: bundle, folder: temp.path),
      throwsStateError,
    );
  });

  test('shows the folder the way its platform opens one', () async {
    final folder = p.join(temp.path, 'browser-extension');
    final calls = <MethodCall>[];
    const channel = MethodChannel('baocode/window');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    // Linux has no `open` (WindowControls' other way): its runner's
    // `revealInFinder` runs `xdg-open` on the folder, written out first.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(await ExtensionFolder.reveal(folder: folder), folder);
    expect(calls.single.method, 'revealInFinder');
    expect(calls.single.arguments, folder);

    // Windows hands it to Explorer through the window's `open` instead.
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(await ExtensionFolder.reveal(folder: folder), folder);
    expect(calls.single.method, 'open');
    expect((calls.single.arguments as Map)['target'], folder);
  });
}

/// An asset bundle with none of the extension's files.
class _NoExtension extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key == 'AssetManifest.bin') {
      return const StandardMessageCodec().encodeMessage(<String, Object>{})!;
    }
    throw StateError('No $key');
  }
}
