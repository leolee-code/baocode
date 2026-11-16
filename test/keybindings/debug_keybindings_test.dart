import 'package:bao_editor/monaco/flutter/keybinding_entry.dart'
    show KeybindingPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/keybindings/default_keybindings.dart';
import 'package:baocode/keybindings/key_chord.dart';
import 'package:baocode/keybindings/keybinding_resolver.dart';
import 'package:baocode/keybindings/window_keybindings.dart';
import 'package:baocode/keybindings/workbench_keybindings.dart';

/// The debugger's default keybindings, resolved as the debugger's context
/// keys give them: F5, F9 and the steps, on macOS and elsewhere.
void main() {
  KeybindingResolver resolverFor(KeybindingPlatform platform) =>
      KeybindingResolver(
        [
          for (final (index, entry) in defaultKeybindings.indexed)
            KeybindingItem(
              entry: entry,
              source: KeybindingSource.defaults,
              platform: platform,
              index: index,
            ),
        ],
        const [],
        knownContextKeys: knownContextKeys,
      );

  String? run(
    KeybindingResolver resolver,
    String keys, {
    String state = 'inactive',
    bool debuggers = true,
    bool editorTextFocus = false,
  }) {
    final context = <String, Object?>{
      'debugState': state,
      'debuggersAvailable': debuggers,
      'inDebugMode': state != 'inactive',
      'editorTextFocus': editorTextFocus,
    };
    final result = resolver.resolve(
      (key) => context[key],
      const [],
      KeySequence.parse(keys)!.chords.single,
    );
    return result is KeybindingFound ? result.command : null;
  }

  final mac = resolverFor(KeybindingPlatform.mac);
  final win = resolverFor(KeybindingPlatform.windows);
  final linux = resolverFor(KeybindingPlatform.linux);
  final all = [mac, win, linux];

  test('every command is in the catalog, every context key is known', () {
    for (final entry in debugKeybindings) {
      expect(commandCatalog, contains(entry.command), reason: entry.command);
    }
    for (final resolver in all) {
      for (final item in resolver.items) {
        if (!debugKeybindings.contains(item.entry)) continue;
        expect(item.unknownContextKeys(knownContextKeys), isEmpty);
      }
    }
  });

  test('F5 starts where nothing runs, and continues where stopped', () {
    for (final resolver in all) {
      expect(run(resolver, 'f5'), 'workbench.action.debug.start');
      expect(run(resolver, 'f5', debuggers: false), isNull);
      expect(run(resolver, 'f5', state: 'initializing'), isNull);
      expect(run(resolver, 'f5', state: 'running'), isNull);
      expect(
        run(resolver, 'f5', state: 'stopped'),
        'workbench.action.debug.continue',
      );
    }
  });

  test('Ctrl+F5 runs without debugging, but while one starts', () {
    for (final resolver in all) {
      expect(run(resolver, 'ctrl+f5'), 'workbench.action.debug.run');
      expect(
        run(resolver, 'ctrl+f5', state: 'running'),
        'workbench.action.debug.run',
      );
      expect(run(resolver, 'ctrl+f5', state: 'initializing'), isNull);
      expect(run(resolver, 'ctrl+f5', debuggers: false), isNull);
    }
  });

  test('stop, restart and pause follow the session', () {
    for (final resolver in all) {
      expect(run(resolver, 'shift+f5'), isNull);
      expect(
        run(resolver, 'shift+f5', state: 'running'),
        'workbench.action.debug.stop',
      );
      expect(
        run(resolver, 'f6', state: 'running'),
        'workbench.action.debug.pause',
      );
      expect(run(resolver, 'f6', state: 'stopped'), isNull);
    }
    expect(run(mac, 'shift+cmd+f5'), isNull);
    expect(
      run(mac, 'shift+cmd+f5', state: 'stopped'),
      'workbench.action.debug.restart',
    );
    for (final resolver in [win, linux]) {
      expect(run(resolver, 'ctrl+shift+f5'), isNull);
      expect(
        run(resolver, 'ctrl+shift+f5', state: 'stopped'),
        'workbench.action.debug.restart',
      );
    }
  });

  test('F10, F11 and Shift+F11 step where stopped', () {
    for (final resolver in all) {
      expect(run(resolver, 'f10'), isNull);
      expect(
        run(resolver, 'f10', state: 'stopped'),
        'workbench.action.debug.stepOver',
      );
      expect(
        run(resolver, 'f11', state: 'stopped'),
        'workbench.action.debug.stepInto',
      );
      expect(
        run(resolver, 'shift+f11', state: 'stopped'),
        'workbench.action.debug.stepOut',
      );
      expect(run(resolver, 'shift+f11', state: 'running'), isNull);
    }
    // F11 is full screen otherwise, where it is (not on macOS: ⌃⌘F).
    for (final resolver in [win, linux]) {
      expect(run(resolver, 'f11'), WindowCommandIds.toggleFullScreen);
      expect(
        run(resolver, 'f11', state: 'running'),
        WindowCommandIds.toggleFullScreen,
      );
    }
    expect(run(mac, 'f11'), isNull);
  });

  test('F9 toggles a breakpoint in a focused editor', () {
    for (final resolver in all) {
      expect(run(resolver, 'f9'), isNull);
      expect(
        run(resolver, 'f9', editorTextFocus: true),
        'editor.debug.action.toggleBreakpoint',
      );
    }
  });

  test('the views have their keys', () {
    expect(run(mac, 'shift+cmd+d'), 'workbench.view.debug');
    expect(run(mac, 'shift+cmd+y'), 'workbench.debug.action.toggleRepl');
    for (final resolver in [win, linux]) {
      expect(run(resolver, 'ctrl+shift+d'), 'workbench.view.debug');
      expect(
        run(resolver, 'ctrl+shift+y'),
        'workbench.debug.action.toggleRepl',
      );
    }
  });
}
