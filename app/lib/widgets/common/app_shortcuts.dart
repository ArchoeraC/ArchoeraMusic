// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/playback/playback_notifier.dart';
import '../../services/shortcuts/shortcut_action.dart';
import '../../services/shortcuts/shortcut_binding.dart';
import '../../settings/settings_dialog.dart';
import '../../stores/app_prefs.dart';
import '../../stores/providers.dart';

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

/// 应用级快捷键（用户可在 设置 → 快捷键 自定义绑定）。
///
/// 实现：根级 [Shortcuts] + [Actions]，绑定表由偏好动态构建（见
/// [ShortcutAction] 注册表）。输入框聚焦时所有动作让位（`consumesKey`
/// 返回 false，按键继续进入文本输入通道）。
class AppShortcuts extends ConsumerWidget {
  const AppShortcuts({super.key, required this.child});

  final Widget child;

  static const seekStep = Duration(seconds: 10);
  static const seekLongStep = Duration(seconds: 30);

  /// 音量步进（对齐 SPlayer-Next VOLUME_STEP = 0.05）。
  static const volumeStep = 0.05;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      _buildAppShortcuts(context, ref);

  static void seek(WidgetRef ref, Duration delta) {
    if (_isTextEditing()) return;
    final notifier = ref.read(playbackProvider.notifier);
    final s = ref.read(playbackProvider);
    if (s.source == null) return;
    var target = s.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > s.duration) target = s.duration;
    notifier.seek(target);
  }

  /// 音量微调（步进 +/-，收敛 0~1）。
  static void adjustVolume(WidgetRef ref, double delta) {
    final notifier = ref.read(playbackProvider.notifier);
    final s = ref.read(playbackProvider);
    // ignore: discarded_futures
    notifier.setVolume(s.volume + delta);
  }
}
