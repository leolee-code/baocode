// docs/egress-policy.md, checked: what this fork removed stays removed, and
// nothing new reaches the network unreviewed. Plain file reads, so it is
// fast: `flutter test test/policy`.
//
// A failure here is not to be fixed by widening a list in passing. Read
// docs/egress-policy.md first; a new entry needs a reason beside it, and a
// person's review.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The app's own Dart code: lib/, and each package's lib/, bin/ (the server
/// a remote host runs) and hook/ (what runs as the app is built).
List<File> _dartSources() {
  final roots = [
    Directory('lib'),
    for (final package in Directory('packages').listSync())
      if (package is Directory)
        for (final part in const ['lib', 'bin', 'hook'])
          Directory('${package.path}/$part'),
  ];
  return [
    for (final root in roots)
      if (root.existsSync())
        for (final entry in root.listSync(recursive: true))
          if (entry is File && entry.path.endsWith('.dart')) entry,
  ]..sort((a, b) => a.path.compareTo(b.path));
}

String _path(File file) => file.path.replaceAll(r'\', '/');

/// [file]'s lines of code: not its comments.
Iterable<String> _code(File file) =>
    file.readAsLinesSync().where((line) => !line.trimLeft().startsWith('//'));

/// What shipped code is read for the publisher's hosts: the app, its
/// packages, the runners, the browser extension and what third_party/
/// builds (BaoCode Bash, docs/bash-exe.md).
List<File> _shipped() {
  const extensions = {
    '.dart', '.swift', '.m', '.mm', '.h', '.c', '.cc', '.cpp', '.js', //
    '.json', '.plist', '.xcconfig', '.entitlements', '.cmake', '.txt',
    '.yaml', '.arb', '.iss', '.sh', '.rs', '.toml',
  };
  final files = <File>[];
  for (final root in const [
    'lib',
    'packages',
    'macos',
    'windows',
    'linux',
    'browser_extension',
    'tool',
    'third_party',
  ]) {
    final directory = Directory(root);
    if (!directory.existsSync()) continue;
    for (final entry in directory.listSync(recursive: true)) {
      if (entry is! File) continue;
      final path = _path(entry);
      if (path.contains('/ephemeral/') ||
          path.contains('/build/') ||
          // cargo's, where one is run in third_party/bash-exe itself.
          path.contains('/target/') ||
          path.contains('/.dart_tool/') ||
          path.contains('/Pods/') ||
          path.contains('/test/')) {
        continue;
      }
      // Of what third_party/ builds, its code and manifests: its test
      // corpora are not all text.
      if (path.startsWith('third_party/') &&
          !(path.endsWith('.rs') || path.endsWith('.toml'))) {
        continue;
      }
      if (extensions.any(path.endsWith)) files.add(entry);
    }
  }
  return files;
}

/// The publisher's domain, whole or put together from pieces
/// (`'baocode' '.dev'`, `'baocode.' + 'dev'`).
final _publisher = RegExp(
  r'''baocode['"\s+.$\{\}]*dev\b''',
  caseSensitive: false,
);

void main() {
  // Rule 1: nothing of the publisher's services.
  test('no code names baocode.dev', () {
    // The site's own pages and a demo's made-up data: not the app.
    const exempt = {
      'tool/build_changelog.dart',
      'tool/showcase/showcase_app.dart',
    };
    final found = <String>[];
    for (final file in _shipped()) {
      final path = _path(file);
      if (exempt.contains(path)) continue;
      // Messages no code shows any more may still say it: only what is
      // generated from them is read, below, by its use.
      if (path.startsWith('lib/l10n/')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (_publisher.hasMatch(lines[i])) found.add('$path:${i + 1}');
      }
    }
    expect(found, isEmpty, reason: 'docs/egress-policy.md, rule 1');
  });

  // Rules 1 and 2: the features removed.
  test('what was removed is not back', () {
    const gone = [
      'lib/telemetry',
      'lib/channel',
      'lib/link',
      'lib/bots',
      'lib/bash_exe',
      'packages/bao_link',
      'packages/bao_iroh',
      'lib/diagnostics/diagnostics_upload.dart',
      'lib/diagnostics/diagnostics_bundle.dart',
      'lib/models/featured_upstreams.dart',
      'lib/models/featured_upstreams_io.dart',
      'lib/models/upstream_import.dart',
      'lib/browser/extension_store.dart',
      'lib/settings/pages/updates_page.dart',
      'lib/settings/pages/mobile_page.dart',
      'lib/settings/pages/channel_account_page.dart',
      'lib/settings/pages/diagnostics_dialog.dart',
      'lib/settings/pages/upstream_import_dialog.dart',
      'lib/settings/pages/featured_upstreams_strip.dart',
      'tool/release_manifest.dart',
      'tool/fetch_remote_server.dart',
    ];
    expect(
      [
        for (final path in gone)
          if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound)
            path,
      ],
      isEmpty,
      reason: 'docs/egress-policy.md, rules 1 and 2',
    );
    // The app's version is all that is left of the updates.
    expect(
      [
        for (final entry in Directory('lib/update').listSync())
          _path(entry as File),
      ],
      ['lib/update/version.dart'],
      reason: 'the app does not update itself (rule 1)',
    );
  });

  test('no name of what was removed is in the code', () {
    final names = RegExp(
      r'\b(TelemetryService|UpdateService|UpdateController|DiagnosticsUploader|'
      r'ChannelSetup|ChannelGate|ChannelAccount|LinkHost|PushWatcher|PhonePush|'
      r'FeaturedUpstream|UpstreamImport|DownloadedServerBinaries|BaoBash|'
      r'ExtensionStore)\b|BAOCODE_CHANNEL|BAOCODE_TELEMETRY_URL|'
      r'BAOCODE_UPDATE_URL|BAOCODE_DIAGNOSTICS_URL|package:bao_link|'
      r'package:bao_iroh|package:bonsoir',
    );
    final found = <String>[];
    for (final file in _dartSources()) {
      if (_path(file).startsWith('lib/l10n/')) continue;
      var number = 0;
      for (final line in file.readAsLinesSync()) {
        number++;
        if (line.trimLeft().startsWith('//')) continue;
        if (names.hasMatch(line)) found.add('${_path(file)}:$number');
      }
    }
    expect(found, isEmpty, reason: 'docs/egress-policy.md, rules 1 and 2');
  });

  // Rule 3: who a commit credits.
  test('commits credit no one unless the user says so', () {
    final source = File('lib/kernel/commit_attribution.dart')
        .readAsStringSync();
    expect(source, contains('static const fallback = none;'));
    expect(source, isNot(contains('baocode,')));
    // A launch of Claude Code that says nothing of it credits no one too.
    final launch = File('lib/kernel/claude_code/claude_code_transport.dart')
        .readAsStringSync();
    expect(launch, contains('this.attribution = CommitAttribution.none,'));
  });

  // Rule 4: every file that opens a connection or listens is known.
  test('only the files listed reach the network', () {
    final reaches = RegExp(
      r'HttpClient\(|HttpClient\.new|WebSocket\.connect|Socket\.connect|'
      r'SecureSocket\.|RawSocket\.|RawSecureSocket|RawDatagramSocket|'
      r'ServerSocket\.bind|HttpServer\.bind|Image\.network|NetworkImage',
    );
    // Each with whom it speaks to. All of them: the model's upstream the
    // user set, a service the user named, or this machine.
    const known = {
      // This machine only (127.0.0.1): the browser extension's bridge, a
      // debug adapter, the model proxy, forwarded ports.
      'lib/browser/browser_bridge.dart',
      'lib/debug/session/stream_debug_adapter.dart',
      'lib/models/proxy/model_proxy.dart',
      'lib/models/proxy/watched_socket.dart',
      'lib/models/magpie_io.dart',
      'lib/remote/port_forwards.dart',
      // A picture a markdown file or a stash links to, shown.
      'lib/ide/markdown/markdown_preview.dart',
      'lib/stash/stash_editor.dart',
      'lib/stash/stash_io_stub.dart',
      // The page a browser tab's source map names.
      'lib/browser/browser_sources.dart',
      // An MCP server the user added, asked what it has.
      'lib/customize/mcp_probe_io.dart',
      // Open VSX, when the user browses themes.
      'lib/extensions/gallery/gallery_http.dart',
      // The user's GitHub and GitLab accounts (no other forge).
      'lib/forge/forge_io.dart',
      // An upstream's site, for its icon; a stashed link's title.
      'lib/icons/site_icon_io.dart',
      'lib/stash/stash_io.dart',
      // Anthropic and OpenAI, with the user's own sign-in.
      'lib/models/claude_resets_io.dart',
      'lib/models/codex/codex_accounts_io.dart',
      // The upstream the user set.
      'lib/models/image_generation_io.dart',
      'lib/models/model_runtime_io.dart',
      // Settings → Network's connection test.
      'lib/network/network_proxy_io.dart',
      // The built-in core: the upstream, the user's hooks, MCP servers and
      // the pages an agent fetches.
      'packages/bao_agent/lib/src/api/anthropic_client.dart',
      'packages/bao_agent/lib/src/hooks/hooks.dart',
      // The built-in core's isolate: its clients trust the machine's own root
      // certificates too (upstream #1048); still the upstream the user set.
      'packages/bao_agent/lib/src/engine/isolate.dart',
      'packages/bao_agent/lib/src/mcp/oauth.dart',
      'packages/bao_agent/lib/src/mcp/transports.dart',
      'packages/bao_agent/lib/src/testing/fake_api.dart',
      'packages/bao_agent/lib/src/tools/web_tools.dart',
      // Claude Code's own releases (downloads.claude.ai), checked.
      'packages/bao_remote/lib/src/claude/claude_release.dart',
      // A remote host's server, over the user's ssh: loopback on each end.
      'packages/bao_remote/lib/src/client/remote_client.dart',
      'packages/bao_remote/lib/src/server/server_cli.dart',
      'packages/bao_remote/lib/src/server/server_session.dart',
      'packages/bao_remote/lib/src/server/server_tcp.dart',
      // Language servers the user installs.
      'packages/bao_remote/lib/src/lsp/install/install_io.dart',
    };
    final found = {
      for (final file in _dartSources())
        if (_code(file).any(reaches.hasMatch)) _path(file),
    };
    expect(
      found.difference(known),
      isEmpty,
      reason:
          'A new file reaches the network. Say in docs/egress-policy.md whom '
          'it speaks to and why, have it reviewed, then list it here.',
    );
    expect(
      known.difference(found),
      isEmpty,
      reason: 'Listed, but it reaches the network no more: take it out.',
    );
  });

  // Rule 4: every host written into the code is known. Any name in a
  // string that reads as a host, however it is dialed (`Uri.https(...)`,
  // `wss://`, a `host:`), not only what follows `https://`.
  test('only the hosts listed are written into the code', () {
    const known = {
      // The models, with the user's own sign-in or key.
      'api.anthropic.com',
      'anthropic.com',
      'claude.ai',
      'platform.claude.com',
      'downloads.claude.ai',
      'api.openai.com',
      'auth.openai.com',
      'chatgpt.com',
      // The user's GitHub and GitLab accounts.
      'github.com',
      'www.github.com',
      'api.github.com',
      'gitlab.com',
      'www.gitlab.com',
      // Emoji pictures, fetched once; themes, when browsed.
      'cdn.jsdelivr.net',
      'open-vsx.org',
      // Settings → Network's connection test, when the user runs it.
      'www.google.com',
      'www.baidu.com',
      'www.youtube.com',
      // Told apart by their address, never dialed unless the user's own
      // upstream is there: how an upstream's API is spoken.
      'open.bigmodel.cn',
      'api.z.ai',
      'dashscope.aliyuncs.com',
      'dashscope-intl.aliyuncs.com',
      'opencode.ai',
      'volces.com',
      'bytepluses.com',
      // A link the user opens, a schema's name, an example.
      'go.microsoft.com',
      'json-schema.org',
      'example.com',
      // Not a host: Arc's app bundle, in a browser's executable path.
      'arc.app',
      'cirw.in',
      'contour-terminal.org',
      'stackoverflow.com',
      'unix.stackexchange.com',
      // Files' names that read as hosts.
      'askpass.sh',
      'install.sh',
      'shellintegration-bash.sh',
      'xcode.app',
      'iterm.app',
    };
    // Lists of names matched against an address the user gave (whose
    // logo an upstream shows; what an agent may read without asking):
    // nothing in them is dialed by the app itself.
    const lists = {
      'lib/models/model_brand.dart',
      'packages/bao_agent/lib/src/tools/web_tools.dart',
    };
    final string = RegExp(r'''\'[^\'\n]*\'|"[^"\n]*"''');
    final host = RegExp(
      r'(?<![A-Za-z0-9_.@-])((?:[a-z0-9-]+\.)+'
      r'(?:com|net|org|dev|io|ai|cn|app|cloud|xyz|me|co|sh|top|site|info|in))'
      r'(?![A-Za-z0-9_.-])',
    );
    final found = <String, String>{};
    for (final file in _dartSources()) {
      final path = _path(file);
      if (path.startsWith('lib/l10n/') || lists.contains(path)) continue;
      for (final line in _code(file)) {
        for (final literal in string.allMatches(line)) {
          for (final match in host.allMatches(literal[0]!.toLowerCase())) {
            found.putIfAbsent(match[1]!, () => path);
          }
        }
      }
    }
    final unknown = {
      for (final MapEntry(:key, :value) in found.entries)
        if (!known.contains(key)) key: value,
    };
    expect(
      unknown,
      isEmpty,
      reason:
          'A new host is written into the code. Say in '
          'docs/egress-policy.md what is sent there and why, have it '
          'reviewed, then list it here.',
    );
  });

  // Rule 4: the runners' own code reaches the network nowhere.
  test('only the native files listed reach the network', () {
    final reaches = RegExp(
      r'URLSession|URLRequest|WKWebView|WinHttp|InternetOpen|'
      r'URLDownloadToFile|curl_|webkit_|soup_|WebView2|getaddrinfo',
    );
    // The channel build's login window: dead code, nothing calls it
    // (docs/egress-policy.md, "已知未处理").
    const known = {
      'macos/Runner/LoginWindow.swift',
      'windows/runner/CMakeLists.txt',
      'windows/runner/login_window.cpp',
      'windows/runner/login_window.h',
      'linux/runner/login_window.cc',
    };
    final found = <String>{};
    for (final root in const [
      'macos/Runner',
      'macos/FinderExtension',
      'macos/BrowserBridge',
      'windows/runner',
      'linux/runner',
    ]) {
      final directory = Directory(root);
      if (!directory.existsSync()) continue;
      for (final entry in directory.listSync(recursive: true)) {
        if (entry is! File) continue;
        final path = _path(entry);
        if (!RegExp(r'\.(swift|m|mm|h|c|cc|cpp|txt|cmake)$').hasMatch(path)) {
          continue;
        }
        if (reaches.hasMatch(entry.readAsStringSync())) found.add(path);
      }
    }
    expect(found.difference(known), isEmpty, reason: 'rule 4');
  });

  // Rule 2: GitHub and GitLab are the only forges an account is of.
  test('no other forge than GitHub and GitLab', () {
    final source = File('lib/forge/forge_ref.dart').readAsStringSync();
    final kinds = RegExp(r'enum ForgeKind \{([^;]*);').firstMatch(source)![1]!;
    expect(
      [for (final kind in kinds.split(',')) kind.trim()],
      ['github', 'gitlab'],
    );
  });

  // Rule 4: a new dependency is a new thing to trust: every package
  // resolved (pubspec.lock), the packages' own and the indirect ones too.
  test('only the packages listed are depended on', () {
    const known = {
      'args', 'async', 'boolean_selector', 'characters', 'clock', //
      'code_assets', 'collection', 'cross_file', 'crypto', 'csslib', 'elk',
      'fake_async', 'ffi', 'ffi_leak_tracker', 'file', 'file_selector_linux',
      'file_selector_platform_interface', 'file_selector_windows', 'flutter',
      'flutter_lints', 'flutter_localizations', 'flutter_math_fork',
      'flutter_svg', 'flutter_test', 'flutter_web_plugins', 'glob', 'hooks',
      'html', 'intl', 'is_ios_simulator', 'katex_dart', 'leak_tracker',
      'leak_tracker_flutter_testing', 'leak_tracker_testing', 'lints',
      'logging', 'markdown', 'matcher', 'material_color_utilities',
      'mermaid_core', 'mermaid_flutter', 'meta', 'native_toolchain_c',
      'nested', 'path', 'path_parsing', 'petitparser',
      'plugin_platform_interface', 'provider', 'pub_semver',
      'quill_native_bridge', 'quill_native_bridge_android',
      'quill_native_bridge_ios', 'quill_native_bridge_linux',
      'quill_native_bridge_macos', 'quill_native_bridge_platform_interface',
      'quill_native_bridge_web', 'quill_native_bridge_windows', 'record_use',
      'sky_engine', 'source_span', 'stack_trace', 'stream_channel',
      'string_scanner', 'super_sliver_list', 'term_glyph', 'test_api',
      'tuple', 'typed_data', 'vector_graphics', 'vector_graphics_codec',
      'vector_graphics_compiler', 'vector_math', 'vm_service', 'web', 'win32',
      'xml', 'yaml',
      // An HTTP client, brought in by flutter_svg and the like: nothing of
      // the app's imports it (checked below).
      'http', 'http_parser',
      // JPEG pictures (lib/images/jpeg_images.dart): image encodes them,
      // archive and posix come with it. None reaches the network.
      'image', 'archive', 'posix',
    };
    final found = {
      for (final line in File('pubspec.lock').readAsLinesSync())
        if (RegExp(r'^  ([a-z_0-9]+):$').firstMatch(line) case final match?)
          match[1]!,
    };
    expect(
      found.difference(known),
      isEmpty,
      reason:
          'A new dependency: read what it does on the network '
          '(docs/egress-policy.md, rule 4), then list it here.',
    );
    final imports = [
      for (final file in _dartSources())
        if (_code(file).any((line) => line.contains('package:http/')))
          _path(file),
    ];
    expect(imports, isEmpty, reason: 'package:http is not to be used');
  });

  // Rule 1: the browser extension is the one this checkout carries, loaded
  // unpacked: nothing makes the browser fetch or update it from elsewhere.
  test('the extension updates from nowhere and calls nothing', () {
    final manifest = File('browser_extension/manifest.json').readAsStringSync();
    expect(manifest, isNot(contains('update_url')));
    expect(manifest, isNot(contains('externally_connectable')));
    expect(manifest, isNot(contains('host_permissions')));
    final script = File('browser_extension/background.js').readAsStringSync();
    expect(
      RegExp(r'\bfetch\(|XMLHttpRequest|new WebSocket|https?://')
          .hasMatch(script),
      isFalse,
      reason: 'the extension speaks to BaoCode alone, by native messaging',
    );
  });

  // Rule 2: nothing announces this computer on the local network.
  test('the macOS app asks for no local network use', () {
    final plist = File('macos/Runner/Info.plist').readAsStringSync();
    expect(plist, isNot(contains('NSBonjourServices')));
    expect(plist, isNot(contains('NSLocalNetworkUsageDescription')));
  });

  // Rule 1: nothing here publishes to, or downloads from, the publisher.
  test('the only workflow is the checks', () {
    final workflows = [
      for (final entry in Directory('.github/workflows').listSync())
        _path(entry as File),
    ];
    expect(workflows, ['.github/workflows/checks.yml']);
  });
}
