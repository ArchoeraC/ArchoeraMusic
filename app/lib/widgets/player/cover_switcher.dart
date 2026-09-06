// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

part 'cover_switcher/cover_switcher_state.dart';

/// 封面切换动效（对齐原项目 FullPlayer/index.vue 的封面 Transition）：
///
/// 切歌（封面 [coverKey] 变化）时旧封面先离场、新封面再入场（Vue
/// `mode="out-in"`，两段动画不重叠）。样式跟随偏好：
/// - scale（默认）：±10px 微位移 + 淡入淡出（对齐 scale-switch）；
/// - slide：全幅滑动（对齐 slide-edge），方向跟随播放顺序：下一首
///   新封面从右进、旧封面向左出；上一首相反。
///
/// 时长/曲线对齐原版：scale 离场 0.2s ease / 入场 0.35s easeOutExpo；
/// slide 离场 0.35s ease / 入场 0.4s easeOutExpo
/// （`cubic-bezier(0.16,1,0.3,1)` 即 Flutter [Curves.easeOutExpo]）。
class CoverSwitcher extends StatefulWidget {
  const CoverSwitcher({
    super.key,
    required this.coverKey,
    required this.slide,
    required this.next,
    required this.child,
  });

  /// 封面身份（切歌即变化，触发 out-in 动效）。
  final Object coverKey;

  /// 滑动样式开关（false = 默认缩放样式）。
  final bool slide;

  /// 切歌方向（true = 下一首，新封面从右进）。
  final bool next;

  final Widget child;

  @override
  State<CoverSwitcher> createState() => _CoverSwitcherState();
}
