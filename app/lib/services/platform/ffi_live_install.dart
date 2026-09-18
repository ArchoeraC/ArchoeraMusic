// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// LiveInstallService 的 FFI 实现（走 apl_live_*；仅 Live 镜像的桥接带这些符号）。
///
/// 桥接侧全程无子进程：磁盘清单读预生成的文件，启动安装经 system bus 调 systemd，
/// 进度同样读文件。这里只做类型转换与转发。
library;

import 'dart:io';

import 'live_install.dart';
import 'platform_bindings.dart';

class FfiLiveInstall implements LiveInstallService {
  FfiLiveInstall(this._b);

  final PlatformBindings _b;

  @override
  bool get available => _b.liveSymbolsAvailable && _b.liveAvailable();

  @override
  List<LiveDisk> disks() => _b.liveDisks();

  @override
  bool start(LivePlan plan) => _b.liveInstallStart(plan);

  @override
  LiveInstallStatus status() =>
      _b.liveInstallStatus() ?? const LiveInstallStatus();

  @override
  bool requestInstaller() {
    if (!available) return false;
    // 这就是「应用自己的运行时目录」里的一个标记文件（Live 镜像用 tmpfiles
    // 建 /run/archoera-install，属主为 kiosk 用户），不涉及任何系统调用或子进程。
    try {
      const dir = '/run/archoera-install';
      if (!Directory(dir).existsSync()) return false;
      File('$dir/request').writeAsStringSync('1\n');
      return true;
    } on FileSystemException {
      return false;
    }
  }
}
