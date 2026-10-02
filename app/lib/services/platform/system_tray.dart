// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// SystemTray 契约：系统托盘图标 + 扁平上下文菜单（自研桥接，替代 tray_manager）。
///
/// 由平台桥接（`apl_tray_*`）实现；桥接未置 [aplCapTray]（未随包/未编译）时由工厂
/// 注入 [NoopSystemTray]，调用方据此降级（不显示托盘、按普通关闭处理）。
///
/// 见 docs/platform-native-bridge.md §3。
library;

import 'dart:async';

import 'platform_failure.dart';

/// 托盘菜单项（Dart 侧模型）：[id]==0 为分隔符；[checked]==-1 表示非复选。
class SystemTrayMenuItem {
  const SystemTrayMenuItem({
    required this.id,
    this.label,
    this.enabled = true,
    this.checked = -1,
  });

  final int id;
  final String? label;
  final bool enabled;
  final int checked;
}

/// 系统托盘能力。返回码：0=成功，负=错误码（见 archoera_platform.h）。
abstract interface class SystemTray {
  /// 创建托盘（[iconPath] 为绝对路径；Windows 用 .ico，其余平台 .png）。幂等。
  int create(String iconPath);

  /// 销毁托盘（幂等）。
  int destroy();

  int setIcon(String iconPath);

  int setTooltip(String tooltip);

  int setVisible(bool visible);

  /// 设置扁平上下文菜单；空列表清除。
  int setMenu(List<SystemTrayMenuItem> items);

  /// 菜单唤出方式：true=左键点击，false=右键。
  int setMenuTrigger(bool leftClick);

  /// 托盘左键单击流。
  Stream<void> get clicks;

  /// 托盘左键双击流。
  Stream<void> get doubleClicks;

  /// 托盘右键流。
  Stream<void> get rightClicks;

  /// 菜单项点击流（值为菜单项 id）。
  Stream<int> get menuCommands;

  /// 执行失败 / 后端断连。
  Stream<PlatformCapabilityFailure> get failures;

  /// 释放底层资源；幂等。
  Future<void> dispose();
}

/// 空实现：让调用方在无托盘能力时静默降级（不显示托盘图标）。
class NoopSystemTray implements SystemTray {
  static final NoopSystemTray instance = NoopSystemTray._();

  NoopSystemTray._();

  static const int _unsupported = -1;

  @override
  int create(String iconPath) => _unsupported;

  @override
  int destroy() => 0;

  @override
  int setIcon(String iconPath) => _unsupported;

  @override
  int setTooltip(String tooltip) => _unsupported;

  @override
  int setVisible(bool visible) => _unsupported;

  @override
  int setMenu(List<SystemTrayMenuItem> items) => _unsupported;

  @override
  int setMenuTrigger(bool leftClick) => _unsupported;

  @override
  Stream<void> get clicks => const Stream<void>.empty();

  @override
  Stream<void> get doubleClicks => const Stream<void>.empty();

  @override
  Stream<void> get rightClicks => const Stream<void>.empty();

  @override
  Stream<int> get menuCommands => const Stream<int>.empty();

  @override
  Stream<PlatformCapabilityFailure> get failures =>
      const Stream<PlatformCapabilityFailure>.empty();

  @override
  Future<void> dispose() async {}
}
