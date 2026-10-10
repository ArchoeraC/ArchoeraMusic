// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'app_prefs.dart';

// ── 电源域键（power. 前缀）────────────────────────────────────
const powerSaverKey = 'power.saver';
const suppressSleepKey = 'power.suppressSleep';

/// 电源域偏好：节能模式、禁用系统休眠与后台卸载页面。
extension PowerPrefs on AppPrefs {
  /// 节能模式（默认开）：窗口最小化（5 FPS）/ 失焦或熄屏（1 FPS）时
  /// 自动降低渲染帧率，恢复前台后回到满帧。
  bool get powerSaver => data[powerSaverKey] as bool? ?? true;

  /// 禁用系统休眠（默认关）：开启后保持系统唤醒，防止后台播放被休眠中断。
  bool get suppressSleep => data[suppressSleepKey] as bool? ?? false;

  /// 节能设置：节能模式总开关 + 禁用系统休眠。
  ///
  /// 注：早期「后台卸载已访问页面」独立开关已废弃——后台 UI 子树卸载统一由
  /// 预设档 `unloadAllMemory`（[PresetPrefs]）驱动，见 `BackgroundUnloadGate`。
  AppPrefs copyWithPower({bool? saver, bool? suppressSleep}) => AppPrefs(
    initialData: {
      ...data,
      powerSaverKey: ?saver,
      suppressSleepKey: ?suppressSleep,
    },
  );
}
