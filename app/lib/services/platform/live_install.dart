// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Live 安装向导的领域模型与服务接口。
///
/// 只有 Live 环境（`/etc/archoera-live`）可用；具体实现见 `ffi_live_install.dart`
/// （走 `apl_live_*` 原生桥接，全程无子进程）。已安装系统上 [available] 为 false，
/// UI 据此不显示安装入口。
library;

/// 候选目标磁盘。
class LiveDisk {
  const LiveDisk({
    required this.name,
    required this.sizeBytes,
    this.model = '',
    this.transport = '',
    this.isLive = false,
  });

  /// 不含 `/dev/`，如 `nvme0n1`。
  final String name;
  final int sizeBytes;
  final String model;

  /// nvme / sata / usb / mmc / …
  final String transport;

  /// 当前 Live 介质所在磁盘：不允许被选为目标。
  final bool isLive;

  /// 内核设备路径。
  String get device => '/dev/$name';

  /// 人类可读容量（GiB，一位小数）。
  String get sizeLabel {
    const gib = 1024 * 1024 * 1024;
    return '${(sizeBytes / gib).toStringAsFixed(1)} GiB';
  }
}

/// 安装计划（对应安装器的 `plan` / `secrets`）。
class LivePlan {
  const LivePlan({
    required this.disk,
    this.hostname = 'archoera',
    this.username = 'archoera',
    this.locale = 'en_US.UTF-8',
    this.timezone = 'UTC',
    this.keymap = 'us',
    this.fs = 'ext4',
    this.swap = 'none',
    this.encrypt = false,
    this.autologin = true,
    this.luksPassphrase = '',
    this.userPassword = '',
    this.rootPassword = '',
  });

  final String disk;
  final String hostname;
  final String username;
  final String locale;
  final String timezone;
  final String keymap;

  /// `ext4` 或 `btrfs`。
  final String fs;

  /// `none` 或 `file`。
  final String swap;
  final bool encrypt;
  final bool autologin;
  final String luksPassphrase;
  final String userPassword;
  final String rootPassword;
}

/// 安装进度。
class LiveInstallStatus {
  const LiveInstallStatus({
    this.running = false,
    this.done = false,
    this.failed = false,
    this.percent = -1,
    this.message = '',
  });

  final bool running;
  final bool done;
  final bool failed;

  /// -1 表示未知。
  final int percent;
  final String message;
}

/// 安装向导服务接口。
abstract interface class LiveInstallService {
  /// 当前是否 Live 环境（决定是否显示安装入口）。
  bool get available;

  /// 候选目标磁盘（由 Live 的 oneshot 单元预先生成清单）。
  List<LiveDisk> disks();

  /// 写计划并启动安装单元；返回是否已启动。
  bool start(LivePlan plan);

  /// 轮询进度。
  LiveInstallStatus status();
}

/// 占位实现：非 Live 环境 / 桥接不可用时使用（不抛异常）。
class UnavailableLiveInstall implements LiveInstallService {
  const UnavailableLiveInstall();

  @override
  bool get available => false;

  @override
  List<LiveDisk> disks() => const <LiveDisk>[];

  @override
  bool start(LivePlan plan) => false;

  @override
  LiveInstallStatus status() => const LiveInstallStatus();
}
