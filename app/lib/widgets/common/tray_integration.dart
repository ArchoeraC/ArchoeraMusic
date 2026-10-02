// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io' show Directory, File, Platform, pid;

import 'package:flutter/services.dart' show rootBundle;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/log/log.dart';
import '../../services/platform/platform_capabilities.dart';
import '../../services/platform/platform_failure.dart';
import '../../services/platform/system_tray.dart';
import '../../services/playback/playback_notifier.dart';
import '../../stores/app_prefs.dart';
import '../../l10n/l10n.dart';
import '../../app/app_quit.dart';
import '../../app/router.dart';
import '../dialogs/s_dialog.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'tray_integration/tray_integration_logic.dart';

/// 后台常驻：系统托盘集成（自研平台桥接 `apl_tray_*`）。
///
/// 2026-10-02 由 Flutter 插件 `tray_manager` 迁至自研桥接：`tray_manager` 0.6+
/// 引入 `nativeapi`/`cnativeapi` 依赖，其第三方 C++ 在 MSVC 下有告警
/// （`strcpy` 弃用 C4996 / `size_t→unsigned long` 收窄 C4267），且按仓库约定
/// 「平台/系统能力一律在 app/native/platform 实现、Dart 只经 apl_* 调用」，
/// 故改由桥接承载托盘并移除该依赖。
///
/// 关闭窗口按「关闭应用时」偏好处理（后台播放 / 直接退出；默认每次询问，
/// 弹确认框含记忆勾选）。托盘菜单：显示主窗口 / 播放暂停 / 上一首 / 下一首 /
/// 退出。托盘初始化失败时降级为正常关闭退出。
class TrayIntegration extends ConsumerStatefulWidget {
  const TrayIntegration({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TrayIntegration> createState() => _TrayIntegrationState();
}

class _TrayIntegrationState extends ConsumerState<TrayIntegration>
    with WindowListener {
  /// 托盘是否就绪（决定关闭窗口是否隐藏到托盘）。
  bool _trayReady = false;

  /// 关闭确认弹窗中「记住我的选择」复选框状态（每次弹窗前重置）。
  bool _closeRemember = false;

  /// 托盘能力实现（进程级单例；本组件只 create/destroy，不 dispose 服务）。
  SystemTray? _tray;

  /// 托盘事件订阅与失败订阅。
  final List<StreamSubscription<void>> _traySubs = <StreamSubscription<void>>[];
  StreamSubscription<PlatformCapabilityFailure>? _trayFailures;

  /// 落到临时文件的图标路径（销毁时清理）。
  String? _iconTempPath;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _disposeTray();
    super.dispose();
  }

  @override
  Future<void> onWindowClose() => _handleWindowClose();

  @override
  Widget build(BuildContext context) => _buildTrayIntegration(context);
}
