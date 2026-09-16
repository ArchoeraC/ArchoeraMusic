// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 当前全屏播放页**自身路由**的进入/退出动画（0 = 未展开，1 = 完全展开）。
///
/// 由 `PlayerPage` 在绑定路由动画时写入、卸载时清空。壳层（`AppShell`）用它
/// 驱动主页的收缩/展开：由于该动画由播放页路由的 Ticker 驱动（一定在逐帧
/// 推进），壳层无需自建 Ticker——从而绕开「下方路由被 Overlay 置为 offstage
/// 时自建 Ticker 不逐帧推进」的问题，且与播放页进出天然同帧同步。
final playerRouteAnimationProvider =
    NotifierProvider<PlayerRouteAnimationNotifier, Animation<double>?>(
      PlayerRouteAnimationNotifier.new,
    );

class PlayerRouteAnimationNotifier extends Notifier<Animation<double>?> {
  @override
  Animation<double>? build() => null;

  /// 写入当前播放页路由动画（null = 无播放页）。
  void set(Animation<double>? animation) {
    if (identical(state, animation)) return;
    state = animation;
  }
}
