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
  static const int output = 1 << 8;
  static const int keyboard = 1 << 9;
}

/// 主输出状态（对齐协议 `output_state`）。
class OsOutputState {
  const OsOutputState({
    required this.width,
    required this.height,
    required this.scaleMilli,
    required this.transform,
    required this.refreshMillihz,
  });

  /// 模式物理像素。
  final int width;
  final int height;

  /// 缩放千分数（1500 = 150%）。
  final int scaleMilli;

  /// 变换（0..7，与 wl_output.transform 一致）。
  final int transform;

  /// 刷新率 × 1000。
  final int refreshMillihz;

  double get scale => scaleMilli / 1000;

  /// 旋转角度（仅 0/90/180/270 有意义）。
  int get rotationDegrees => switch (transform) {
    1 || 5 => 90,
    2 || 6 => 180,
    3 || 7 => 270,
    _ => 0,
  };
}

/// 一个显示输出的可用模式（对齐协议 `output_mode`）。
///
/// [index] 是该输出模式表里的下标，设置时原样交给
/// [SystemOsSession.setDisplayOutputMode]。
class OsDisplayMode {
  const OsDisplayMode({
    required this.index,
    required this.width,
    required this.height,
    required this.refreshMillihz,
    required this.isCurrent,
    required this.isPreferred,
  });

  final int index;
  final int width;
  final int height;

  /// 刷新率 × 1000（165000 = 165.00Hz）。
  final int refreshMillihz;

  /// 该模式正在使用中。
  final bool isCurrent;

  /// 显示器首选模式。
  final bool isPreferred;

  double get refreshHz => refreshMillihz / 1000;

  /// 下拉列表文案：`2560×1600 @165.00 Hz`。
  String get label =>
      '$width×$height @${refreshHz.toStringAsFixed(refreshHz % 1 == 0 ? 0 : 2)} Hz';
}

/// 一个显示输出（对齐协议 `output_info` + `output_current` + 模式表）。
class OsDisplayOutput {
  const OsDisplayOutput({
    required this.id,
    required this.name,
    required this.enabled,
    required this.primary,
    required this.width,
    required this.height,
    required this.scaleMilli,
    required this.transform,
    required this.refreshMillihz,
    required this.modes,
  });

  /// 协议输出 id（原样传给设置函数）。
  final int id;

  /// 连接器名（如 `eDP-1` / `HDMI-A-1`）。
  final String name;

  final bool enabled;
  final bool primary;

  /// 当前模式。
  final int width;
  final int height;
  final int refreshMillihz;

  /// 当前缩放千分数（1500 = 150%）。
  final int scaleMilli;

  /// 当前变换（0..7，与 wl_output.transform 一致）。
  final int transform;

  /// 该输出的完整模式列表（下拉列表数据源）。
  final List<OsDisplayMode> modes;

  double get scale => scaleMilli / 1000;

  int get rotationDegrees => switch (transform) {
    1 || 5 => 90,
    2 || 6 => 180,
    3 || 7 => 270,
    _ => 0,
  };

  /// 当前模式在 [modes] 中的下标（找不到返回 null）。
  int? get currentModeIndex {
    for (final m in modes) {
      if (m.isCurrent) return m.index;
    }
    return null;
  }

  /// 当前模式文案；模式表里没有对应项时回退到当前状态字段。
  String get currentModeLabel {
    for (final m in modes) {
      if (m.isCurrent) return m.label;
    }
    return '$width×$height @${(refreshMillihz / 1000).toStringAsFixed(1)} Hz';
  }
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

  /// 显示设置（仅 [OsCapability.output] 置位时生效）。
  /// [scaleMilli] 千分数（1500 = 150%）；[width]/[height] 为 0 表示首选模式；
  /// [transform] 见 [OsOutputState.transform]。
  int setOutputScale(int scaleMilli);
  int setOutputMode(int width, int height);
  int setOutputTransform(int transform);

  /// per-output 显示快照（协议 v5；含每个输出的完整模式列表）。
  ///
  /// 快照式读取：显示设置页打开/点刷新时调用一次即可，不依赖常驻事件订阅。
  /// 未接入 archoera-shell 或桥接为旧版（无 v5 符号）时返回空列表。
  List<OsDisplayOutput> displayOutputs();

  /// 按索引切换某个输出的模式（[index] 来自 [OsDisplayOutput.modes]）。
  int setDisplayOutputMode(int outputId, int index);

  /// 设置某个输出的缩放（千分数；合成器夹取到 100%-400%）。
  int setDisplayOutputScale(int outputId, int scaleMilli);

  /// 设置某个输出的变换（旋转/镜像；见 [OsDisplayOutput.transform]）。
  int setDisplayOutputTransform(int outputId, int transform);

  /// 注入一个按键（屏幕键盘 → 合成器 → 焦点客户端/输入法）。
  ///
  /// [keycode] 为 evdev 键码（KEY_*，如 A=30），并非 Flutter 的 logical key；
  /// [state] 0=释放 1=按下。仅 [OsCapability.keyboard] 置位时生效。修饰键由调用方
  /// 自行按下/释放（如 Shift+A）。合成器按物理键盘路径处理，输入法可正常消费。
  int key(int keycode, int state);

  /// 会话能力位图（archoera_shell_v1 capability）。
  Stream<int> get capabilities;

  /// 亮度 / 音量（0-100）。
  Stream<int> get brightness;
  Stream<int> get volume;

  Stream<OsBatteryState> get battery;
  Stream<OsSessionState> get session;
  Stream<bool> get screenEnabled;
  Stream<OsPowerKey> get powerKey;

  /// 主输出状态（订阅成功后合成器立即下发一次，之后变化时下发）。
  Stream<OsOutputState> get output;
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
  int setOutputScale(int scaleMilli) => -1;

  @override
  int setOutputMode(int width, int height) => -1;

  @override
  int setOutputTransform(int transform) => -1;

  @override
  List<OsDisplayOutput> displayOutputs() => const <OsDisplayOutput>[];

  @override
  int setDisplayOutputMode(int outputId, int index) => -1;

  @override
  int setDisplayOutputScale(int outputId, int scaleMilli) => -1;

  @override
  int setDisplayOutputTransform(int outputId, int transform) => -1;

  @override
  int key(int keycode, int state) => -1;

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

  @override
  Stream<OsOutputState> get output => const Stream.empty();
}
