// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

/// 进程级窗口全屏状态（**唯一一处**注册原生窗口事件监听）。
///
/// ## 为什么必须集中管理（Windows 下整个应用卡死）
///
/// `nativeapi` 的 `Window.isFullScreen` 在**非窗口线程**调用时会先 `PostToThread`
/// 再 `wait_for(..., 5s)` **同步等待**窗口线程执行（见 cnativeapi
/// `OnWindowThread`，Linux/macOS 不触发该分支，故只有 Windows 会中招）。
///
/// 播放页原实现有两条叠加路径：
/// 1. 每次 `initState` 都**同步**读 `isFullScreen` 做初始校准；
/// 2. **每个实例各自** `addListener` / `removeListener` 原生窗口监听。
///
/// 关闭后迅速重开时，新旧 `PlayerPage` 实例短暂重叠，上述同步跨线程调用会成倍
/// 叠加；一旦窗口线程正忙，UI 线程就被阻塞数秒——用户看到的就是「整个软件卡死」。
///
/// ## 现在的契约
///
/// - 进程内**只注册一次**原生监听（首次读取本 provider 时），随 provider 存活，
///   页面反复挂载/卸载不再增删原生监听；
/// - 全屏状态**只由窗口事件更新**（进入 / 退出全屏），读状态是纯内存操作，
///   热路径上没有任何原生调用；
/// - 唯一的原生写入是用户点「全屏」按钮（[toggle]），不在挂载路径上。
///
/// 初始值取 `false`：应用没有「启动即全屏」的偏好，且刻意不去读那个会阻塞的
/// 同步 getter；若启动时真有全屏事件，监听器会立即校正。
final windowFullScreenProvider =
    NotifierProvider<WindowFullScreenNotifier, bool>(
      WindowFullScreenNotifier.new,
    );

class WindowFullScreenNotifier extends Notifier<bool> {
  Window? _window;
  ListenerId? _listenerId;

  /// 单元测试（`flutter_tester`）里没有真实窗口：`getCurrent()` 这类 FFI 调用会
  /// 停在原生侧不返回（Dart 侧超时都触发不了），挂载播放页的 widget 测试会直接
  /// 卡死。测试环境只保留纯内存状态（与仓库其它 FFI/烘焙路径同一约定）。
  static bool get _nativeWindowAvailable =>
      !Platform.environment.containsKey('FLUTTER_TEST');

  @override
  bool build() {
    _attach();
    ref.onDispose(() {
      final listenerId = _listenerId;
      if (listenerId != null) _window?.removeListener(listenerId);
      _listenerId = null;
      _window = null;
    });
    return false;
  }

  /// 取当前窗口并注册（一次）原生窗口事件监听。
  ///
  /// 首次读取 provider 时窗口一定已存在（播放页在窗口之后才可打开）；若极端
  /// 情况下取不到（无窗口环境 / 单元测试），[_currentWindow] 返回 null 且不抛错。
  void _attach() {
    if (!_nativeWindowAvailable) return;
    if (_listenerId != null) return;
    final window = _window ??= _currentWindow();
    if (window == null) return;
    try {
      _listenerId = window.addListener(_onWindowEvent);
    } catch (_) {
      _listenerId = null;
    }
  }

  /// 取当前窗口；无窗口环境（单元测试 / 启动早期）静默降级为 null。
  Window? _currentWindow() {
    try {
      return WindowManager.instance.getCurrent();
    } catch (_) {
      return null;
    }
  }

  void _onWindowEvent(WindowEvent event) {
    if (event is WindowEnteredFullScreenEvent && !state) {
      state = true;
    } else if (event is WindowExitedFullScreenEvent && state) {
      state = false;
    }
  }

  /// 用户点「全屏」：先乐观置位（图标即时反馈），随后由窗口事件校准。
  ///
  /// 写入本身仍是跨线程同步调用，但只发生在**用户主动点击**时，不在页面挂载 /
  /// 转场路径上，不参与「快速开关」的叠加。
  void toggle() {
    final target = !state;
    state = target;
    _attach();
    final window = _window;
    if (window == null) return;
    try {
      window.isFullScreen = target;
    } catch (_) {
      // 原生写入失败：状态仍以事件为准，这里不回滚以免图标闪烁。
    }
  }
}
