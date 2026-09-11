// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 自绘右键菜单（对齐 SPlayer-Next SContextMenu 语义，替代 Material
/// 系统菜单观感）。
///
/// 用法：
/// ```dart
/// SContextMenu.show(
///   context,
///   position: globalPosition,
///   items: [
///     SContextMenuItem(label: '播放', icon: EtaIcons.play, onTap: ...),
///     SContextMenuItem.divider(),
///     SContextMenuItem(label: '删除', icon: EtaIcons.delete, danger: true, onTap: ...),
///   ],
/// );
/// ```
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../common/anim.dart';
part 's_context_menu/s_context_menu_view.dart';

/// 右键菜单项。
class SContextMenuItem {
  const SContextMenuItem({
    required this.label,
    this.icon,
    this.onTap,
    this.danger = false,
    this.disabled = false,
    this.divider = false,
  });

  const SContextMenuItem.divider()
    : label = '',
      icon = null,
      onTap = null,
      danger = false,
      disabled = false,
      divider = true;

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;

  /// 危险操作（删除等，红色文字）。
  final bool danger;
  final bool disabled;

  /// 分隔线项。
  final bool divider;
}

/// 自绘右键菜单（覆盖层实现，点击外部 / ESC 关闭，右/下溢出自动翻转）。
class SContextMenu {
  SContextMenu._();

  /// 菜单宽度。
  static const double menuWidth = 220;

  /// 单项高度。
  static const double itemHeight = 38;

  static void show(
    BuildContext context, {
    required Offset position,
    required List<SContextMenuItem> items,
  }) {
    if (items.isEmpty) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _SContextMenuOverlay(
        position: position,
        items: items,
        onClose: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
  }
}

class _SContextMenuOverlay extends StatefulWidget {
  const _SContextMenuOverlay({
    required this.position,
    required this.items,
    required this.onClose,
  });

  final Offset position;
  final List<SContextMenuItem> items;
  final VoidCallback onClose;

  @override
  State<_SContextMenuOverlay> createState() => _SContextMenuOverlayState();
}

class _SContextMenuOverlayState extends State<_SContextMenuOverlay> {
  /// 菜单显示动画进度（0→1，入场 scale + fade）。
  double _t = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _t = 1);
    });
  }

  @override
  Widget build(BuildContext context) => _buildSContextMenuOverlay(context);
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({required this.item, required this.onClose});

  final SContextMenuItem item;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => _buildMenuItem(context);
}
