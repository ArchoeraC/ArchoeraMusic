// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/playback/playback_notifier.dart';
import '../../stores/app_prefs.dart';
import '../../l10n/l10n.dart';
import '../../app/app_quit.dart';
import '../../app/router.dart';
import '../dialogs/s_dialog.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'tray_integration/tray_integration_logic.dart';

/// 后台常驻：系统托盘集成。
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
    with WindowListener, TrayListener {
  /// 托盘是否就绪（决定关闭窗口是否隐藏到托盘）。
  bool _trayReady = false;

  /// 关闭确认弹窗中「记住我的选择」复选框状态（每次弹窗前重置）。
  bool _closeRemember = false;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  @override
  Future<void> onWindowClose() => _handleWindowClose();

  @override
  void onTrayIconMouseDown() => _handleTrayIconMouseDown();

  @override
  void onTrayIconRightMouseDown() => _handleTrayIconRightMouseDown();

  @override
  Widget build(BuildContext context) => _buildTrayIntegration(context);
}
