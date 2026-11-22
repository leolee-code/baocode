import 'dart:async';

import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/widgets.dart';

import '../../ide/ide_menu.dart';
import '../../l10n/l10n.dart';
import '../../platform/windows_shell.dart';
import 'settings_dropdown.dart';
import 'settings_widgets.dart';

/// [shell]'s name in the list.
String windowsShellName(BuildContext context, WindowsShell shell) =>
    switch (shell) {
      WindowsShell.baoBash => 'BaoCode Bash',
      WindowsShell.gitBash => 'Git Bash',
      WindowsShell.cmd => 'cmd',
      WindowsShell.powershell => 'PowerShell',
      WindowsShell.custom => context.l10n.commandLineShellCustom,
    };

/// Settings → General → Command Line (Windows): the shell agents run
/// commands in, picked from a list (BaoCode Bash where the app carries it,
/// Git Bash where it is installed); under it the file of a custom one.
class CommandLineSettings extends StatelessWidget {
  const CommandLineSettings({super.key, required this.shells});

  final WindowsShells shells;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: shells,
    builder: (context, _) {
      final shown = shells.shown;
      return SettingsCard(
        children: [
          _shellRow(context, shown),
          if (shown == WindowsShell.custom)
            SettingsRow(
              label: context.l10n.commandLineCustomPath,
              description: context.l10n.commandLineCustomPathDescription,
              trailing: SettingsTextField(
                value: shells.customPath ?? '',
                hint: r'C:\path\to\bash.exe',
                semanticLabel: context.l10n.commandLineCustomPath,
                width: 260,
                onSubmitted: (path) => unawaited(shells.setCustomPath(path)),
              ),
            ),
        ],
      );
    },
  );

  Widget _shellRow(BuildContext context, WindowsShell shown) {
    final l10n = context.l10n;
    final inUse = shells.inUse;
    final name = windowsShellName(context, shown);
    return SettingsRow(
      label: l10n.commandLineShell,
      description: l10n.commandLineShellDescription,
      below: [
        SelectableText(
          inUse.shell == shown
              ? l10n.commandLineShellInUse(inUse.executable)
              : l10n.commandLineShellFallback(name, inUse.executable),
          style: SettingsText.path,
        ),
      ],
      trailing: SettingsDropdown(
        current: name,
        semanticLabel: '${l10n.commandLineShell}: $name',
        entries: () => [
          for (final shell in WindowsShell.values)
            if (switch (shell) {
              WindowsShell.baoBash => shells.baoBash != null,
              WindowsShell.gitBash => shells.gitBash != null,
              _ => true,
            })
              IdeMenuAction(
                windowsShellName(context, shell),
                checked: shell == shown,
                onSelected: () => unawaited(shells.choose(shell)),
              ),
        ],
      ),
    );
  }
}
