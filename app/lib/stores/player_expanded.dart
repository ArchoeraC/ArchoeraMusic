// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 全屏播放器展开信号（对齐原项目 status.isPlayerExpanded）。
///
/// `PlayerPage` 挂载时置 true、卸载时置 false；壳层据此做收起/展开
/// 动画（MainLayout 的 `scale-95 opacity-0 pointer-events-none`）。
final playerExpandedProvider = NotifierProvider<PlayerExpandedNotifier, bool>(
  PlayerExpandedNotifier.new,
);

class PlayerExpandedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// 设置展开态（PlayerPage 生命周期驱动，缺省折叠）。
  void set(bool value) => state = value;
}
