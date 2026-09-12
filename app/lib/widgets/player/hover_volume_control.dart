// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../services/playback/playback_notifier.dart';
import 'ctrl_icon.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'hover_volume/hover_volume_control_state.dart';

/// 悬浮式音量控件（默认隐藏滑条，hover 展开）：
/// - 只显示音量图标；滑条默认收起
/// - 光标悬浮在整个音量组件上超过 800ms → 滑条展开
/// - 展开后鼠标移出且 5s 未操作 → 自动隐藏（期间重新悬浮则取消隐藏）
/// - 拖动中仅预览（引擎命令 80ms 合并、prefs 不落盘），松开落盘最终值
/// - 静音切换内置音量记忆（无记忆回退 0.7）
class HoverVolumeSlider extends ConsumerStatefulWidget {
  const HoverVolumeSlider({super.key, this.sliderWidth = 96});

  /// 展开时滑条的宽度（逻辑像素）。
  final double sliderWidth;

  @override
  ConsumerState<HoverVolumeSlider> createState() => _HoverVolumeSliderState();
}
