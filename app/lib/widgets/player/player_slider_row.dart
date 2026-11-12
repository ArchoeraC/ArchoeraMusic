// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放页滑杆行的统一栅格：`[前置槽][轨道][后置槽]`。
///
/// 进度行（时间 / 轨道 / 时长）与音量行（图标 / 轨道 / 空槽）共用同一
/// [gutter] 与 [gap]，两条轨道的左右边缘因此严格对齐（Vutron 经典布局的
/// 两条 `.progress-bar`）。以后要加静音百分比、倍速等，只需补一个槽位，
/// 不必再各自摆 Row。
///
/// 只负责**布局**；轨道本身的样式由调用方传入的滑块组件声明（进度/音量
/// 目前共用 `PlaybackSlider`，对齐 SPlayer-Next 用同一个 `SSlider` 声明
/// 不同样式参数的做法）。
library;

import 'package:material_ui/material_ui.dart';

class PlayerSliderRow extends StatelessWidget {
  const PlayerSliderRow({
    super.key,
    required this.leading,
    required this.track,
    this.trailing = const SizedBox.shrink(),
    this.gutter = defaultGutter,
    this.gap = defaultGap,
    this.leadingAlignment = Alignment.centerLeft,
    this.trailingAlignment = Alignment.centerLeft,
  });

  /// 两侧槽宽默认值（能放下 "00:00" 与 16px 图标）。
  static const double defaultGutter = 44;

  /// 槽与轨道之间的留白。
  static const double defaultGap = 12;

  /// 前置槽内容（进度行：已播放时间；音量行：静音图标）。
  final Widget leading;

  /// 后置槽内容（进度行：总时长；音量行：默认空）。
  final Widget trailing;

  /// 轨道（进度 / 音量滑块）。
  final Widget track;

  /// 两侧槽位宽度（左右对称 → 轨道居中对齐）。
  final double gutter;

  /// 槽位与轨道的间距。
  final double gap;

  final Alignment leadingAlignment;
  final Alignment trailingAlignment;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: gutter,
          child: Align(alignment: leadingAlignment, child: leading),
        ),
        SizedBox(width: gap),
        Expanded(child: track),
        SizedBox(width: gap),
        SizedBox(
          width: gutter,
          child: Align(alignment: trailingAlignment, child: trailing),
        ),
      ],
    );
  }
}
