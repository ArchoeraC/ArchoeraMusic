// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'app_prefs.dart';

// ── 愚人节特供 · 整活模式（easterEgg.aprilFools. 前缀）────────────

/// 整活模式是否处于激活态（默认关）。
///
/// 激活后跨重启保留，直到用户点击「我投降」写入 [aprilFoolsSurrenderedYear]。
const aprilFoolsKey = 'easterEgg.aprilFools';

/// 已投降的年份（用户点过「我投降」后当年不再自动激活）。
const aprilFoolsSurrenderedYearKey = 'easterEgg.aprilFoolsSurrenderedYear';

/// 是否允许愚人节整活（默认开）。关闭后**永不**自动激活（设置页可随时关）。
const aprilFoolsEnabledKey = 'easterEgg.aprilFoolsEnabled';

/// 愚人节特供「整活模式」偏好。
extension EasterEggPrefs on AppPrefs {
  /// 整活模式是否激活（默认关）。
  bool get aprilFools => data[aprilFoolsKey] as bool? ?? false;

  /// 已投降年份；未投降过为 null。
  int? get aprilFoolsSurrenderedYear =>
      data[aprilFoolsSurrenderedYearKey] as int?;

  /// 是否允许愚人节整活（默认开）。关闭后永不自动激活。
  bool get aprilFoolsEnabled => data[aprilFoolsEnabledKey] as bool? ?? true;

  AppPrefs copyWithAprilFools(bool value) =>
      AppPrefs(initialData: {...data, aprilFoolsKey: value});

  AppPrefs copyWithAprilFoolsEnabled(bool value) =>
      AppPrefs(initialData: {...data, aprilFoolsEnabledKey: value});

  AppPrefs copyWithAprilFoolsSurrenderedYear(int year) =>
      AppPrefs(initialData: {...data, aprilFoolsSurrenderedYearKey: year});
}
