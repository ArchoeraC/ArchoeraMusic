// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'app_prefs.dart';

// ── 愚人节特供 · 奇怪的特效（easterEgg.aprilFools 前缀）────────────

/// 「奇怪的特效」已被开启（消耗）的年份。
///
/// 该特效**仅允许在愚人节当天、且当年尚未开启过**时手动开启一次：开启即写入
/// 当年，设置项立即消失；此后无论是手动关闭、重启应用还是点击「我投降」，都
/// 不会再恢复——直到次年 4/1 重新出现。
const aprilFoolsUsedYearKey = 'easterEgg.aprilFoolsUsedYear';

/// 愚人节特供「奇怪的特效」偏好。
extension EasterEggPrefs on AppPrefs {
  /// 已开启过「奇怪的特效」的年份；从未开启为 null。
  int? get aprilFoolsUsedYear => data[aprilFoolsUsedYearKey] as int?;

  AppPrefs copyWithAprilFoolsUsedYear(int year) =>
      AppPrefs(initialData: {...data, aprilFoolsUsedYearKey: year});
}
