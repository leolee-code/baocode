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

  testWidgets('says what BaoCode is, which build, and where it is made', (
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
      find.text('github.com/baocode-dev/baocode · 免费开源，GPL-3.0 许可证'),
      findsOneWidget,
    );
    expect(find.text('去 GitHub 点 Star'), findsOneWidget);
    // docs/egress-policy.md: no link to the publisher's site.
    expect(find.text('baocode.dev'), findsNothing);
    expect(find.text('更新日志'), findsNothing);
    expect(find.text('反馈问题'), findsOneWidget);
    expect(find.text('设备 ID'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('its links', () {
    expect(
      AboutSettingsPage.issues,
      Uri.parse('https://github.com/baocode-dev/baocode/issues'),
    );
  });
}
