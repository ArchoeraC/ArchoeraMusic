// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 窗口装饰方案切换（系统原生 / 自绘标题条 / 无边框）。
///
/// 只在桌面端生效；非桌面或窗口尚未创建时静默跳过，由调用方回退到默认外观。
library;

import 'dart:io' show Platform;

import 'package:window_manager/window_manager.dart';

import '../log/log.dart';

/// 窗口装饰方案 id（与 `appearance.windowDecor` 持久化值一致）。
abstract final class WindowDecor {
  static const system = 'system';
  static const caption = 'caption';
  static const borderless = 'borderless';
}

bool get _isDesktop =>
    Platform.isLinux || Platform.isWindows || Platform.isMacOS;

/// 把装饰方案应用到当前窗口。
///
/// - [WindowDecor.borderless]：去掉原生边框与系统窗口按钮（等价
///   SPlayer-Next 的 `frame: false`），窗口内容铺满；
/// - [WindowDecor.caption]：保留系统边框，仅隐藏标题栏，由自绘标题条接管；
/// - [WindowDecor.system]：恢复系统原生标题栏。
void applyWindowDecor(String mode) {
  if (!_isDesktop || Platform.environment.containsKey('FLUTTER_TEST')) return;
  try {
    final window = WindowManager.instance.getCurrent();
    if (window == null) return;
    switch (mode) {
      case WindowDecor.borderless:
        window.setFrameless(true);
      case WindowDecor.caption:
        window.setFrameless(false);
        window.titleBarStyle = TitleBarStyle.hidden;
      default:
        window.setFrameless(false);
        window.titleBarStyle = TitleBarStyle.normal;
    }
  } catch (e) {
    Log.w('window', '应用窗口装饰方案失败（$mode）: $e');
  }
}
