// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// SystemPower 契约：OS 防休眠抑制 + 熄屏状态。
///
/// 平台原语差异（Linux D-Bus portal / Win SetThreadExecutionState /
/// macOS NSProcessInfo / Android wakelock）全部藏在实现内；
/// 平台缺失时由工厂注入 [NoopSystemPower] 静默降级。
///
/// 门禁语义：调用方负责「仅在媒体播放中抑制」（见 power_saver 的
/// setPlaying 双条件），本接口不内嵌播放状态机。
///
/// 见 docs/platform-capability-facade.md §2.1 / §7.2。
library;

import 'dart:async';

import 'platform_failure.dart';

/// 防休眠/屏保抑制 + 熄屏状态订阅。
abstract interface class SystemPower {
  /// 开/关系统休眠抑制。返回是否成功生效；**false = 执行失败，调用方
  /// （设置页/播放联动）必须 toast 显式告警**（facade §5 降级两档）。
  Future<bool> setSleepInhibit(bool on, {String reason = 'playback'});

  /// 熄屏/屏保激活状态流（true = 屏幕关闭或屏保激活）。
  /// 平台不支持时输出 null（仅首值，之后无事件）。
  Stream<bool> get screenState;

  /// 开/关熄屏状态订阅（订阅后才推送 [screenState]）。
  /// 失败仅 debug 回落（后台优化类，不 toast——facade §5 降级两档）。
  Future<bool> setScreenEvents(bool on);

  /// 执行失败 / 后端断连上抛（如 ScreenSaver 服务中途消失）。
  Stream<PlatformCapabilityFailure> get failures;

  /// 释放底层资源（D-Bus 连接等）；幂等。
  Future<void> dispose();
}

/// 空实现：一切静默降级（无休眠抑制、无熄屏事件）。
class NoopSystemPower implements SystemPower {
  static final NoopSystemPower instance = NoopSystemPower._();

  NoopSystemPower._();

  @override
  Future<bool> setSleepInhibit(bool on, {String reason = 'playback'}) async =>
      false;

  @override
  Stream<bool> get screenState => const Stream.empty();

  @override
  Future<bool> setScreenEvents(bool on) async => false;

  @override
  Stream<PlatformCapabilityFailure> get failures => const Stream.empty();

  @override
  Future<void> dispose() async {}
}
