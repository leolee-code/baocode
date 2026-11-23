import 'package:flutter/widgets.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../../update/version.dart';
import '../../workspace/window_header/about_dialog.dart' show aboutIconAsset;
import 'settings_widgets.dart';

/// Settings → About: what BaoCode is and which build this is.
class AboutSettingsPage extends StatelessWidget {
  const AboutSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsPage(
      title: l10n.settingsSectionAbout,
      lead: Padding(
        padding: const EdgeInsets.fromLTRB(8, 18, 8, 0),
        child: Row(
          // 图标与右侧三行文字整体垂直居中
          children: [
            // 与标题栏、任务栏同一张应用图标，保留原始配色；
            // 图片自带约 10% 透明边，放大到 72 才能与右侧文字块相称
            Image.asset(
              aboutIconAsset,
              width: 72,
              height: 72,
              filterQuality: FilterQuality.high,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        'BaoCode',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        l10n.aboutVersion(
                          currentAppVersion.marketing,
                          currentAppVersion.build,
                        ),
                        style: TextStyle(
                          color: AppColors.textFaint,
                          fontSize: 12,
                          fontFamily: AppFonts.mono,
                          fontFamilyFallback: AppFonts.monoFallbacks,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(l10n.aboutTagline, style: SettingsText.lead),
                  const SizedBox(height: 6),
                  Text(
                    l10n.aboutDescription,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      children: const [],
    );
  }
}
