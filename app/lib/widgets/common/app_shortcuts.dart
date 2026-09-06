// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/playback/playback_notifier.dart';

part 'app_shortcuts/app_shortcuts_actions.dart';

/// 焦点是否落在文本输入控件上。
///
/// 注意：TextField 的 focusNode 实际附着在内部 `Focus` widget 上，
/// `primaryFocus.context.widget` 是 Focus 而非 EditableText，直接做
/// `widget is EditableText` 会漏判，导致输入框聚焦时快捷键不让位
/// （空格被截走 / Ctrl+F、Esc 触发导航）。故同时检查祖先链。
bool _isTextEditing() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  return ctx.widget is EditableText ||
      ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// 应用级快捷键（对齐原版 hotkey 体系的核心播放/导航动作）。
///
/// 实现：根级 [Shortcuts] + [Actions]。Flutter 按键分发按最近匹配优先，
/// 输入框内的方向键/回车等由 EditableText 的快捷键先于本层消费。
/// 空格不在 EditableText 快捷键内，若本层直接吞掉会截走输入框的空格
/// 字符，故 [Space] 走自定义 [_PlayPauseAction]：输入框聚焦时
/// `consumesKey` 返回 false（事件以 skipRemainingHandlers 继续进入
/// 文本输入通道，空格照常输入且不触发播放/暂停）。
///
/// 内置：
///  - Space        播放/暂停（输入框聚焦时让位）
///  - ← / →        后退/前进 10s（有播放源时）
///  - Ctrl/Cmd+↑/↓ 音量 +/- 0.05（对齐 SPlayer-Next volumeUp/volumeDown）
///  - Ctrl/Cmd+F   搜索页（隐藏分支）
///  - Ctrl/Cmd+L   音乐库
///  - Esc          返回（关闭弹窗/全屏播放器）
class AppShortcuts extends ConsumerWidget {
  const AppShortcuts({super.key, required this.child});

  final Widget child;

  static const _seekStep = Duration(seconds: 10);

  /// 音量步进（对齐 SPlayer-Next VOLUME_STEP = 0.05）。
  static const double _volumeStep = 0.05;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      _buildAppShortcuts(context, ref);

  /// 主焦点是否落在文本输入（导航类快捷键让位，避免输入中被劫持）。
  bool get _editing => _isTextEditing();

  void _seek(WidgetRef ref, Duration delta) {
    // 输入框内方向键是光标移动，不触发 seek
    if (_editing) return;
    final notifier = ref.read(playbackProvider.notifier);
    final s = ref.read(playbackProvider);
    if (s.source == null) return;
    var target = s.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > s.duration) target = s.duration;
    notifier.seek(target);
  }

  /// 音量微调（步进 +/-，收敛 0~1；对齐 SPlayer-Next volumeUp/volumeDown）。
  void _adjustVolume(WidgetRef ref, double delta) {
    final notifier = ref.read(playbackProvider.notifier);
    final s = ref.read(playbackProvider);
    // ignore: discarded_futures
    notifier.setVolume(s.volume + delta);
  }
}
