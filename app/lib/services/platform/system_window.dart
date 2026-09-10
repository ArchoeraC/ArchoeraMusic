// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// SystemWindow 契约：窗口最小化/失焦状态探测（2026-09-10 新增）。
///
/// 事件由原生桥接（X11 / WndProc 子类化 / NSWindow 通知）探测并回传；
/// 桥接未置能力位（纯 Wayland 等）时由工厂注入 [NoopSystemWindow]，
/// 调用方（power_saver）回退 window_manager 监听（既有路径）。
///
/// 见 docs/platform-capability-facade.md §2.1 / docs/platform-native-bridge.md §3.4。
library;

import 'dart:async';

import 'platform_failure.dart';

/// 窗口状态快照（桥接按事件即时推送，无轮询）。
class SystemWindowState {
  const SystemWindowState({required this.minimized, required this.focused});

  final bool minimized;
  final bool focused;

  @override
  bool operator ==(Object other) =>
      other is SystemWindowState &&
      other.minimized == minimized &&
      other.focused == focused;

  @override
  int get hashCode => Object.hash(minimized, focused);
}

/// 窗口状态事件订阅。
abstract interface class SystemWindow {
  /// 开/关事件订阅。返回是否成功生效（失败时调用方仅 debug 日志回落，
  /// 不 toast——后台优化类，见 facade §5 降级两档）。
  Future<bool> setEvents(bool on);

  /// 状态快照流（订阅即收到当前已知状态；能力缺失时空流）。
  Stream<SystemWindowState> get state;

  /// 执行失败 / 后端断连上抛（UI toast 由消费方决定；本能力默认仅日志）。
  Stream<PlatformCapabilityFailure> get failures;

  /// 释放底层资源；幂等。
  Future<void> dispose();
}

/// 空实现：无事件（调用方回退 window_manager），静默降级。
class NoopSystemWindow implements SystemWindow {
  static final NoopSystemWindow instance = NoopSystemWindow._();

  NoopSystemWindow._();

  @override
  Future<bool> setEvents(bool on) async => false;

  @override
  Stream<SystemWindowState> get state => const Stream.empty();

  @override
  Stream<PlatformCapabilityFailure> get failures => const Stream.empty();

  @override
  Future<void> dispose() async {}
}
