/// 国际化接入层：locale 解析 + 非 Widget 层文案访问 + context 扩展。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../stores/app_prefs.dart';
import 'generated/app_localizations.dart';

/// 当前生效 Locale：设置的语言优先，否则跟随系统。
final localeProvider = Provider<Locale>((ref) {
  final code = ref.watch(appPrefsProvider).locale;
  if (code != null && code.isNotEmpty) {
    final parts = code.split('-');
    return Locale(parts.first, parts.length > 1 ? parts[1] : null);
  }
  // 跟随系统
  return PlatformDispatcher.instance.locale;
});

/// 当前语言的本地化文案（无 BuildContext 场景：controller / notifier）。
final l10nProvider = Provider<AppLocalizations>(
  (ref) => lookupAppLocalizations(ref.watch(localeProvider)),
);

/// `context.l10n` 便捷访问（Widget 层）。
extension AppLocalizationsContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

/// 本地化音质标签。
String l10nQualityLabel(AppLocalizations l10n, String quality) {
  switch (quality) {
    case 'lossless':
      return l10n.qualityLossless;
    case 'hi-res':
      return 'Hi-Res';
    case 'hq':
      return 'HQ';
    case 'sq':
      return 'SQ';
    case 'lq':
      return 'LQ';
    default:
      return quality;
  }
}

/// 本地化播放模式标签。
String l10nRepeatModeLabel(AppLocalizations l10n, String mode) {
  switch (mode) {
    case 'list':
      return l10n.repeatModeList;
    case 'one':
      return l10n.repeatModeOne;
    default:
      return mode;
  }
}
