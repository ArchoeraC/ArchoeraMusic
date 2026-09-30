// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'app_prefs.dart';

// ── 电源域键（power. 前缀）────────────────────────────────────
const powerSaverKey = 'power.saver';
const suppressSleepKey = 'power.suppressSleep';
const unloadBackgroundPagesKey = 'power.unloadBackgroundPages';

/// 电源域偏好：节能模式、禁用系统休眠与后台卸载页面。
extension PowerPrefs on AppPrefs {
  /// 节能模式（默认开）：窗口最小化（5 FPS）/ 失焦或熄屏（1 FPS）时
  /// 自动降低渲染帧率，恢复前台后回到满帧。
  bool get powerSaver => data[powerSaverKey] as bool? ?? true;

  /// 禁用系统休眠（默认关）：开启后保持系统唤醒，防止后台播放被休眠中断。
  bool get suppressSleep => data[suppressSleepKey] as bool? ?? false;

  /// 后台卸载已访问页面（默认关）：最小化/托盘隐藏/熄屏时把壳内页面
  /// （列表/封面/滚动状态）临时卸载为占位，恢复窗口后重建——用少量重建立
  /// 成本换后台常驻内存（见 docs/runtime-resource-optimization.md §4）。
  /// 关闭时页面常驻（保持滚动位置，无重建）。
  bool get unloadBackgroundPages =>
      data[unloadBackgroundPagesKey] as bool? ?? false;

  /// 节能设置：节能模式总开关 + 禁用系统休眠 + 后台卸载页面。
  AppPrefs copyWithPower({
    bool? saver,
    bool? suppressSleep,
    bool? unloadBackgroundPages,
  }) => AppPrefs(
    initialData: {
      ...data,
      powerSaverKey: ?saver,
      suppressSleepKey: ?suppressSleep,
      unloadBackgroundPagesKey: ?unloadBackgroundPages,
    },
  );
}
