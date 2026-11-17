import 'dart:io';

import 'package:bao_agent/bao_agent.dart' show Shell;
import 'package:path/path.dart' as p;

import 'windows_shell.dart';

/// The shells on this machine to pick from; null anywhere but Windows.
WindowsShellHost? windowsShellHost() =>
    Platform.isWindows ? _Host(Platform.environment) : null;

class _Host implements WindowsShellHost {
  _Host(this._environment);

  final Map<String, String> _environment;

  @override
  String? gitBash() => Shell.gitBash(_environment);

  String get _systemRoot =>
      _environment['SystemRoot'] ?? _environment['SYSTEMROOT'] ?? r'C:\Windows';

  @override
  String cmd() =>
      _environment['ComSpec'] ??
      _environment['COMSPEC'] ??
      p.windows.join(_systemRoot, 'System32', 'cmd.exe');

  @override
  String powershell() {
    final path = _environment['PATH'] ?? _environment['Path'] ?? '';
    for (final dir in path.split(';')) {
      if (dir.isEmpty) continue;
      final pwsh = p.windows.join(dir, 'pwsh.exe');
      if (File(pwsh).existsSync()) return pwsh;
    }
    return p.windows.join(
      _systemRoot,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
  }
}
