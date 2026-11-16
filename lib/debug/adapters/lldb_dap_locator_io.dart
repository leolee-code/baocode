import 'dart:io';

import 'package:path/path.dart' as p;

import '../../kernel/claude_code/claude_environment.dart';
import 'lldb_dap_locator.dart';

/// The search on this machine: with the login shell's environment, as a
/// terminal would find lldb-dap, which the app started from the Finder
/// would not.
abstract final class LldbDapLocator {
  static Future<String?> locate({String? configured}) async {
    final environment = {
      ...Platform.environment,
      ...await ClaudeEnvironment.of(),
    };
    return LldbDapSearch(
      environment: environment,
      isMacOS: Platform.isMacOS,
      exists: FileSystemEntity.isFileSync,
      list: _list,
      xcrun: (tool) => _xcrun(tool, environment),
    ).find(configured: configured);
  }

  static List<String> _list(String directory) {
    try {
      return [
        for (final entity in Directory(directory).listSync())
          p.basename(entity.path),
      ];
    } on FileSystemException {
      return const [];
    }
  }

  /// `xcrun -f <tool>`.
  static Future<String?> _xcrun(
    String tool,
    Map<String, String> environment,
  ) async {
    try {
      // Asked first whether there are developer tools at all: without
      // them xcrun is the stub that offers to install them, in a dialog.
      final selected = await Process.run('/usr/bin/xcode-select', [
        '-p',
      ], environment: environment);
      if (selected.exitCode != 0) return null;
      final found = await Process.run('/usr/bin/xcrun', [
        '-f',
        tool,
      ], environment: environment);
      if (found.exitCode != 0) return null;
      final path = '${found.stdout}'.trim();
      return path.isEmpty ? null : path;
    } on Object {
      // No xcrun, or one that does not say.
      return null;
    }
  }
}
