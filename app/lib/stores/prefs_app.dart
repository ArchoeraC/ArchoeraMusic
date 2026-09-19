// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'app_prefs.dart';

// ── 应用级键（app. 前缀）──────────────────────────────────────
const closeBehaviorKey = 'app.closeBehavior';
const developerModeKey = 'app.developerMode';

/// 开发者组件开关键（会话级，默认全关）：
/// 「FPS/内存监控浮层」独立开关，跟随开发者模式，关闭应用后一并重置。
const devFpsMonitorKey = 'app.devFpsMonitor';

/// 开发者「下载模块」独立开关（会话级，默认关）：
/// 侧边栏「下载」入口、曲目右键「下载」与设置「下载」分类仅在
/// 开发者模式 + 本开关同时开启后显示（开启前会弹出风险确认）。
const devDownloadModuleKey = 'app.devDownloadModule';

/// 关闭应用时行为（ask=每次询问 / background=后台播放 / quit=直接退出）。
const String defaultCloseBehavior = 'ask';

/// 应用级偏好：关闭行为与开发者模式。
extension AppLevelPrefs on AppPrefs {
  /// 关闭应用时行为（非法值回退默认）。
  String get closeBehavior {
    final v = data[closeBehaviorKey];
    if (v is String && (v == 'background' || v == 'quit')) return v;
    return defaultCloseBehavior;
  }

  /// 开发者模式（默认关）：隐藏的下载接口（侧边栏 / 右键菜单 /
  /// 设置-下载分类）仅在开启后显示。设置-关于内长按「版本」10 秒开启。
  /// **会话级开关**：不持久化，关闭应用后下次启动强制回到关闭状态
  /// （见 [AppPrefsNotifier.build]）。
  bool get developerMode => data[developerModeKey] as bool? ?? false;

  /// 设置「关闭应用时」行为（ask/background/quit）。
  AppPrefs copyWithCloseBehavior(String value) =>
      AppPrefs(initialData: {...data, closeBehaviorKey: value});

  AppPrefs copyWithDeveloperMode(bool value) =>
      AppPrefs(initialData: {...data, developerModeKey: value});

  /// 开发者「FPS/内存监控浮层」开关（默认关，见 [devFpsMonitorKey]）。
  bool get devFpsMonitor => data[devFpsMonitorKey] as bool? ?? false;

  AppPrefs copyWithDevFpsMonitor(bool value) =>
      AppPrefs(initialData: {...data, devFpsMonitorKey: value});

  /// 开发者「下载模块」开关（默认关，见 [devDownloadModuleKey]）。
  bool get devDownloadModule => data[devDownloadModuleKey] as bool? ?? false;

  /// 下载模块是否真正可用（开发者模式 + 下载模块开关同时开启）。
  ///
  /// 侧边栏入口 / 右键菜单 / 设置分类统一以此判定，避免各处重复
  /// 组合 [developerMode] 与 [devDownloadModule]。
  bool get downloadModuleEnabled => developerMode && devDownloadModule;

  AppPrefs copyWithDevDownloadModule(bool value) =>
      AppPrefs(initialData: {...data, devDownloadModuleKey: value});
}
