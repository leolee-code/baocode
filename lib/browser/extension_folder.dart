import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../platform/app_platform.dart';
import '../platform/data_dir.dart';
import '../workspace/window_controls.dart';

/// BaoCode's browser extension, as this build carries it: the checkout's
/// `browser_extension/`, among the app's assets (pubspec.yaml). Nothing is
/// fetched for it (docs/egress-policy.md): the user loads it unpacked
/// from [path], which [prepare] writes out of the app, since a browser
/// cannot pick a folder inside a macOS app bundle. Its key (manifest.json)
/// gives it the id the browsers' host lets in (BrowserBridge.extensionIds).
abstract final class ExtensionFolder {
  /// Where its files are among the assets.
  static const assetPrefix = 'browser_extension/';

  /// The folder it is loaded from: the data folder's `browser-extension`.
  static String get path =>
      p.join(DataDirectory.current.path, 'browser-extension');

  /// Writes the extension this build carries into [folder] ([path] by
  /// default), in place of what was there: after an update, the browser
  /// takes the new one once it is reloaded there. Gives the folder.
  static Future<String> prepare({AssetBundle? bundle, String? folder}) async {
    bundle ??= rootBundle;
    folder ??= path;
    final manifest = await AssetManifest.loadFromAssetBundle(bundle);
    final assets = [
      for (final asset in manifest.listAssets())
        if (asset.startsWith(assetPrefix)) asset,
    ];
    if (!assets.contains('${assetPrefix}manifest.json')) {
      throw StateError('This build carries no browser extension.');
    }
    final directory = Directory(folder);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
    for (final asset in assets) {
      final data = await bundle.load(asset);
      final file = File(
        p.joinAll([folder, ...asset.substring(assetPrefix.length).split('/')]),
      );
      file.parent.createSync(recursive: true);
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    return folder;
  }

  /// Whether the system can show a folder in its file manager.
  static bool get canReveal =>
      WindowControls.canRevealInFileManager || AppPlatform.isWindows;

  /// [prepare]s it and shows the folder in Finder or File Explorer.
  static Future<String> reveal() async {
    final folder = await prepare();
    if (AppPlatform.isMacOS) {
      await WindowControls.revealInFileManager(folder);
    } else {
      await WindowControls.openExternal(folder);
    }
    return folder;
  }
}
