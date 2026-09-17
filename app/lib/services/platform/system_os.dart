// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// SystemOsSession 契约：ArchoeraOS 合成器会话（`archoera_shell_v1`）。
///
/// 运行于普通桌面（未接 `archoera-shell`）时桥接不置能力位，工厂注入空实现，
/// 全部静默降级。媒体键/音量键经既有媒体命令流复用（见 [SystemMedia]）。
///
/// 设计依据：`docs/archoera-os.md` §7；原生实现 `os_session_linux.cpp`。
library;

import 'dart:async';

/// 会话状态（对齐协议 `session_state`）。
enum OsSessionState { ready, shuttingDown, suspending }

/// 电源键（对齐协议 `power_key`）。
enum OsPowerKey { power, sleep, suspend }

/// archoera_shell_v1 能力位（与协议 `capability` 一致）。
abstract final class OsCapability {
  static const int brightness = 1 << 0;
  static const int power = 1 << 1;
  static const int volume = 1 << 2;
  static const int mediaKeys = 1 << 3;
  static const int battery = 1 << 4;
  static const int suspend = 1 << 5;
  static const int powerKey = 1 << 6;
  static const int screen = 1 << 7;
}

/// 电池快照。
class OsBatteryState {
  const OsBatteryState({
    required this.present,
    required this.percent,
    required this.charging,
  });

  final bool present;
  final int percent;
  final bool charging;
}

/// ArchoeraOS 会话接口。
abstract interface class SystemOsSession {
  /// 桥接是否提供该能力（原生符号存在；仍可能因不在 archoera-shell 下而无事件）。
  bool get available;

  /// 订阅/退订会话事件；订阅成功后合成器会立即下发当前状态。
  /// 返回 0 = 成功，负 = 不可用。
  int setEvents(bool on);

  /// 系统请求（无对应能力位时合成器静默忽略）。
  int setBrightness(int percent);
  int setVolume(int percent);
  int setScreenEnabled(bool on);
  int powerOff();
  int reboot();
  int suspend();
  int hibernate();

  /// 会话能力位图（archoera_shell_v1 capability）。
  Stream<int> get capabilities;

  /// 亮度 / 音量（0-100）。
  Stream<int> get brightness;
  Stream<int> get volume;

  Stream<OsBatteryState> get battery;
  Stream<OsSessionState> get session;
  Stream<bool> get screenEnabled;
  Stream<OsPowerKey> get powerKey;
}

/// 空实现：未接 ArchoeraOS 会话时静默降级。
class NoopSystemOsSession implements SystemOsSession {
  static final NoopSystemOsSession instance = NoopSystemOsSession._();

  NoopSystemOsSession._();

  @override
  bool get available => false;

  @override
  int setEvents(bool on) => -1;

  @override
  int setBrightness(int percent) => -1;

  @override
  int setVolume(int percent) => -1;

  @override
  int setScreenEnabled(bool on) => -1;

  @override
  int powerOff() => -1;

  @override
  int reboot() => -1;

  @override
  int suspend() => -1;

  @override
  int hibernate() => -1;

  @override
  Stream<int> get capabilities => const Stream.empty();

  @override
  Stream<int> get brightness => const Stream.empty();

  @override
  Stream<int> get volume => const Stream.empty();

  @override
  Stream<OsBatteryState> get battery => const Stream.empty();

  @override
  Stream<OsSessionState> get session => const Stream.empty();

  @override
  Stream<bool> get screenEnabled => const Stream.empty();

  @override
  Stream<OsPowerKey> get powerKey => const Stream.empty();
}
