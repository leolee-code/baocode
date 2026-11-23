import 'package:baocode/l10n/app_localizations.dart';
import 'package:baocode/settings/pages/about_page.dart';
import 'package:baocode/update/version.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> show(WidgetTester tester, Locale locale) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: const AboutSettingsPage()),
      ),
    );
    await tester.pump();
  }

  testWidgets('says what BaoCode is and which build, with no upstream links', (
    tester,
  ) async {
    await show(tester, const Locale('zh'));
    expect(find.text('关于'), findsOneWidget);
    expect(find.text('BaoCode'), findsOneWidget);
    expect(
      find.text(
        '版本 ${currentAppVersion.marketing}（${currentAppVersion.build}）',
      ),
      findsOneWidget,
    );
    expect(
      find.text('智能体以本地进程运行 Claude Code；它们所做的一切——消息、工具、差异和面板——都显示在这里。'),
      findsOneWidget,
    );
    // docs/egress-policy.md: no links to the publisher's site or public repo.
    expect(find.text('去 GitHub 点 Star'), findsNothing);
    expect(find.text('反馈问题'), findsNothing);
    expect(find.textContaining('baocode-dev/baocode'), findsNothing);
    expect(find.text('baocode.dev'), findsNothing);
    expect(find.text('更新日志'), findsNothing);
    expect(find.text('设备 ID'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
