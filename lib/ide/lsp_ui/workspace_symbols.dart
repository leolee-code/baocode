import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../l10n/l10n.dart';
import '../ide_fuzzy.dart';
import '../ide_quick_input.dart';
import '../lsp/language_features.dart';
import '../lsp/lsp_protocol.dart';
import 'language_icons.dart';

/// The workspace's symbols matching a query, asked of the servers
/// (debounced) as the query changes, for Go to Symbol in Workspace.
class IdeWorkspaceSymbols extends ChangeNotifier {
  IdeWorkspaceSymbols(this.languages);

  final LanguageFeatures languages;

  static const delay = Duration(milliseconds: 150);

  String _query = '';
  List<LspWorkspaceSymbol> _symbols = const [];
  bool _loading = false;
  bool _supported = false;
  Timer? _timer;
  int _request = 0;
  bool _disposed = false;

  /// What [symbols] are asked for.
  String get query => _query;

  /// The last answer: an earlier query's while [loading].
  List<LspWorkspaceSymbol> get symbols => _symbols;

  /// Whether [query]'s answer is still awaited.
  bool get loading => _loading;

  /// Whether a running server searches the workspace's symbols.
  bool get supported => languages.supportsWorkspaceSymbols;

  /// Asks for [query]'s symbols after [delay], in place of the query
  /// before it; none for an empty one. Tells no listener of what it
  /// changes at once, the rows asking read it next.
  void search(String query) {
    query = query.trim();
    if (_disposed || query == _query) return;
    _query = query;
    _ask();
  }

  /// The servers changed: asks those that can now search, forgets the
  /// answer of those that no longer run.
  void refresh() {
    if (_disposed || supported == _supported) return;
    _ask();
    notifyListeners();
  }

  /// Forgets the query and its answer (the quick input opens anew).
  void clear() {
    if (_disposed) return;
    _query = '';
    _ask();
  }

  void _ask() {
    _timer?.cancel();
    _request++;
    _supported = supported;
    final query = _query;
    if (query.isEmpty || !_supported) {
      _symbols = const [];
      _loading = false;
      return;
    }
    _loading = true;
    _timer = Timer(delay, () => unawaited(_fetch(query)));
  }

  Future<void> _fetch(String query) async {
    final request = _request;
    List<LspWorkspaceSymbol> symbols;
    try {
      symbols = await languages.workspaceSymbols(query);
    } catch (_) {
      symbols = const [];
    }
    // A later query's answer is the one awaited.
    if (_disposed || request != _request) return;
    _symbols = symbols;
    _loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// Rows for Go to Symbol in Workspace (the `#` prefix): [symbols] as the
/// servers matched them, those whose name matches [filter] first, the best
/// first; only those while [loading], when [symbols] answer an earlier
/// query. [fileOf] is a symbol's file as its row names it. Messages in
/// [l10n]'s language (English when null).
List<IdeQuickPickItem> workspaceSymbolQuickPicks(
  String filter, {
  required List<LspWorkspaceSymbol> symbols,
  required bool loading,
  required bool supported,
  required String Function(LspWorkspaceSymbol symbol) fileOf,
  required void Function(LspWorkspaceSymbol symbol) onGo,
  AppLocalizations? l10n,
}) {
  final strings = l10n ?? englishLocalizations;
  if (!supported) {
    return [IdeQuickPickItem(label: strings.workspaceSymbolsNoServer)];
  }
  final query = filter.trim();
  if (query.isEmpty) return const [];
  final matched = <(int, LspWorkspaceSymbol, IdeFuzzyMatch)>[];
  final others = <LspWorkspaceSymbol>[];
  for (final (index, symbol) in symbols.indexed) {
    final match = ideFuzzyMatch(query, symbol.name);
    if (match != null) {
      matched.add((index, symbol, match));
    } else if (!loading) {
      // Matched by the server on more than its name (`ns::name`).
      others.add(symbol);
    }
  }
  if (matched.isEmpty && others.isEmpty) {
    return [
      IdeQuickPickItem(
        label: loading
            ? strings.symbolsLoading
            : strings.workspaceSymbolsNoMatching,
      ),
    ];
  }
  // Stable: equal scores keep the servers' order.
  matched.sort((a, b) {
    final byScore = b.$3.score.compareTo(a.$3.score);
    return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
  });
  IdeQuickPickItem row(
    LspWorkspaceSymbol symbol, [
    List<int> matches = const [],
  ]) {
    final kindIcon = ideSymbolKindIcon(symbol.kind);
    final file = fileOf(symbol);
    return IdeQuickPickItem(
      label: symbol.name,
      labelMatches: matches,
      description: switch (symbol.containerName) {
        final container? when container.isNotEmpty => '$container • $file',
        _ => file,
      },
      icon: Icon(kindIcon.icon, size: 15, color: kindIcon.color),
      onAccept: () => onGo(symbol),
    );
  }

  return [
    for (final (_, symbol, match) in matched) row(symbol, match.positions),
    for (final symbol in others) row(symbol),
  ];
}
