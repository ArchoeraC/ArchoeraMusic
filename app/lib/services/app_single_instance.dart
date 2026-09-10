// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

/// 应用单实例守卫（跨平台）。
///
/// 机制：运行时目录下的**独占文件锁**（`RandomAccessFile.lock`）保证唯一实例；
/// 另监听回环端口用于「二次启动 → 激活既有窗口」。锁获取失败 → 说明已有实例，
/// 发送激活信号后由调用方退出。
///
/// - 锁路径：Linux 优先 `$XDG_RUNTIME_DIR`，否则系统临时目录；Windows/macOS 用临时目录。
/// - 激活端口固定回环（失败仅失去“自动置前”，不影响单实例语义）。
/// - 锁由进程持有至退出（进程结束自动释放）。
class SingleInstance {
  SingleInstance._();

  static const int _activatePort = 47110;

  static RandomAccessFile? _lock;
  static ServerSocket? _server;

  /// 二次启动时（收到激活信号）回调，用于显示/聚焦既有窗口。
  static void Function()? onActivate;

  /// 尝试成为唯一实例。返回 true = 本进程是首实例（继续启动）；
  /// false = 已有实例（已尽力激活，调用方应退出）。
  static Future<bool> acquire() async {
    final dir = Platform.environment['XDG_RUNTIME_DIR'] ??
        Directory.systemTemp.path;
    final lockPath = '$dir/archoera_music.lock';
    try {
      final raf = await File(lockPath).open(mode: FileMode.write);
      await raf.lock(FileLock.exclusive);
      _lock = raf;
    } catch (_) {
      await _signalExisting();
      return false;
    }

    // 首实例：监听激活请求（失败仅降级，不影响单实例）
    try {
      _server = await ServerSocket.bind(
          InternetAddress.loopbackIPv4, _activatePort);
      _server!.listen((s) {
        s.destroy();
        onActivate?.call();
      });
    } catch (_) {
      // 端口被占用/受限：单实例仍由文件锁保证
    }
    return true;
  }

  static Future<void> _signalExisting() async {
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4,
          _activatePort, timeout: const Duration(milliseconds: 300));
      s.write('activate');
      await s.flush();
      s.destroy();
    } catch (_) {
      // 既有实例未监听端口：忽略，直接退出
    }
  }

  /// 释放（测试/热重载用；正常进程退出自动释放）。
  static Future<void> release() async {
    await _server?.close();
    _server = null;
    try {
      await _lock?.unlock();
      await _lock?.close();
    } catch (_) {}
    _lock = null;
  }
}
