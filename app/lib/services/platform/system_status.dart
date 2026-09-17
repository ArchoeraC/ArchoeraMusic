// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 系统资源与蓝牙状态只读快照（`apl_sys_stats` / `apl_bt_state`）。
///
/// 轮询式（无事件）：UI 可见时定时读取，不可见即停。桥接不支持时工厂注入
/// 空实现，全部静默降级。
library;

/// 系统资源快照（CPU/内存/磁盘/运行时长/温度）。
class SysStats {
  const SysStats({
    required this.cpuCount,
    required this.cpuPercent,
    required this.memTotalKb,
    required this.memAvailableKb,
    required this.swapTotalKb,
    required this.swapFreeKb,
    required this.diskTotalKb,
    required this.diskFreeKb,
    required this.uptimeSec,
    required this.tempMillic,
  });

  final int cpuCount;

  /// 0-100；-1 = 首次采样（无基准）。
  final int cpuPercent;

  final int memTotalKb;
  final int memAvailableKb;
  final int swapTotalKb;
  final int swapFreeKb;
  final int diskTotalKb;
  final int diskFreeKb;
  final int uptimeSec;

  /// 温度 ×1000；<0 = 无传感器。
  final int tempMillic;

  int get memUsedKb => (memTotalKb - memAvailableKb).clamp(0, memTotalKb);

  int get memPercent =>
      memTotalKb > 0 ? ((memUsedKb * 100) ~/ memTotalKb) : 0;

  int get diskUsedKb => (diskTotalKb - diskFreeKb).clamp(0, diskTotalKb);

  int get diskPercent =>
      diskTotalKb > 0 ? ((diskUsedKb * 100) ~/ diskTotalKb) : 0;

  /// 温度（摄氏度，一位小数）；null = 不可得。
  double? get tempCelsius => tempMillic < 0 ? null : tempMillic / 1000;

  /// 运行时长（`HH:MM:SS`，超过一天按总小时数累计）。
  String get uptimeLabel {
    final h = uptimeSec ~/ 3600;
    final m = (uptimeSec % 3600) ~/ 60;
    final s = uptimeSec % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(h)}:${two(m)}:${two(s)}';
  }
}

/// 蓝牙适配器状态（BlueZ）。
class BluetoothState {
  const BluetoothState({
    required this.present,
    required this.powered,
    required this.discoverable,
    required this.pairable,
    required this.devicesConnected,
    required this.adapterName,
  });

  final bool present;
  final bool powered;
  final bool discoverable;
  final bool pairable;
  final int devicesConnected;

  /// 适配器名（不可得为 null）。
  final String? adapterName;
}

/// 系统状态只读接口。
abstract interface class SystemStatus {
  /// 桥接是否提供系统资源能力。
  bool get statsAvailable;

  /// 桥接是否提供蓝牙能力（BlueZ 可达）。
  bool get bluetoothAvailable;

  /// 读取快照；不可用返回 null。
  SysStats? stats();

  /// 读取蓝牙状态；不可用返回 null。
  BluetoothState? bluetooth();
}

/// 空实现：桥接不支持时静默降级。
class NoopSystemStatus implements SystemStatus {
  static final NoopSystemStatus instance = NoopSystemStatus._();

  NoopSystemStatus._();

  @override
  bool get statsAvailable => false;

  @override
  bool get bluetoothAvailable => false;

  @override
  SysStats? stats() => null;

  @override
  BluetoothState? bluetooth() => null;
}
