// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 后台卸载门：应用进入不可见后台（最小化 / 托盘隐藏 / 熄屏）且用户开启了
/// 「后台卸载页面」或「最小化时卸载全部内存状态」时，把**整个 UI 子树**
/// （`MaterialApp` + 路由 + 所有页面）替换为纯色占位，释放页面/图片内存；
/// 恢复窗口后重建。
///
/// 与 `ShellExpandTransition`（播放页展开时卸载壳内容）是同一思路，但作用范围
/// 是根级：连播放页、弹窗在内的全部路由一起卸掉。
///
/// 时序保证（见 `PowerSaverService._apply`）：后台态变化后由服务先放行并请求
/// **一帧**跑本门的卸载，帧后再停帧/释放数据——否则最小化时先停帧会让卸载帧
/// 永远不来。
///
/// 强迫症「卸载全部内存状态」额外把全局路由器复位到首页（`appRouter.go('/')`），
/// 丢弃分支/Tab/嵌套路由状态；温和档只卸载 UI、保留导航状态。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/power/power_saver.dart';
import '../stores/app_prefs.dart';
import 'router.dart';

class BackgroundUnloadGate extends ConsumerStatefulWidget {
  const BackgroundUnloadGate({super.key, required this.child});

  /// 被卸载的应用子树（`MaterialApp.router`）。
  final Widget child;

  @override
  ConsumerState<BackgroundUnloadGate> createState() =>
      _BackgroundUnloadGateState();
}

class _BackgroundUnloadGateState extends ConsumerState<BackgroundUnloadGate> {
  /// 上一次是否处于「已卸载」态（用于仅在进入后台的那一刻做一次复位）。
  bool _wasUnloaded = false;

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(appPrefsProvider);
    // UI 子树卸载仅由强迫症档（unloadAllMemory）开启；默认不做 UI 卸载。
    final unloadEnabled = prefs.unloadAllMemory;
    final hidden = ref.watch(appInBackgroundProvider);
    final unloaded = unloadEnabled && hidden;

    if (unloaded && !_wasUnloaded) {
      _wasUnloaded = true;
      // 强迫症「不保留任何内存态」：复位路由到首页，丢弃分支/Tab/嵌套路由状态
      // （全局 GoRouter 不随 MaterialApp 卸载而重建，需显式复位）。
      if (prefs.unloadAllMemory) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          try {
            appRouter.go('/');
          } catch (_) {
            // 路由复位失败无害（下次重建仍会挂载当前状态）
          }
        });
      }
    } else if (!unloaded && _wasUnloaded) {
      _wasUnloaded = false;
    }

    if (!unloaded) return widget.child;
    // 纯色占位：不依赖 Directionality/Localizations（MaterialApp 已卸下）。
    return const ColoredBox(color: Color(0xFF000000));
  }
}
