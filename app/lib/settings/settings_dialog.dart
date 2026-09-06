// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 全局设置弹窗（对齐原项目 SettingsDialog：左侧分类菜单 + 右侧内容区）。
///
/// 各分类内容组件拆在 [settings_sections.dart]（AppearanceSection /
/// PlaybackSection / LyricsSection / PresetSection / DownloadSection /
/// ScrapeSection / StorageSection / AboutSection / DeveloperSection），
/// 本文件保留弹窗骨架：分类导航 / 搜索 / 开发者长按开启逻辑。
library;

import 'dart:async' show Timer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../stores/app_prefs.dart';
import '../theme/app_theme.dart';
import '../widgets/common/anim.dart';
import '../widgets/common/glass_surface.dart';
import '../widgets/common/toast.dart';
import 'cache_section.dart';
import 'history_section.dart';
import 'scans_section.dart';
import 'security_section.dart';
import 'settings_categories.dart';
import 'settings_sections.dart';
import 'streaming_server_list.dart';

export 'settings_categories.dart';

part 'settings/settings_dialog_actions.dart';
part 'settings/settings_dialog_view.dart';

void showSettingsDialog(BuildContext context, {SettingsCategory? category}) {
  showDialog<void>(
    context: context,
    // 全局变暗遮罩（统一所有弹窗样式）
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (_) => SettingsDialog(initialCategory: category),
  );
}

class _SearchEntry {
  const _SearchEntry(this.category, this.title, this.subtitle, this.icon);
  final SettingsCategory category;
  final String title;
  final String subtitle;
  final IconData icon;
}

class SettingsDialog extends ConsumerStatefulWidget {
  const SettingsDialog({super.key, this.initialCategory});

  /// 打开时选中的分类（默认 appearance）。
  final SettingsCategory? initialCategory;

  @override
  ConsumerState<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<SettingsDialog> {
  late SettingsCategory _category =
      widget.initialCategory ?? SettingsCategory.appearance;
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  String _version = '';

  // ── 开发者模式：长按「版本」10 秒开启（按住进度反馈）──
  Timer? _devHoldTimer;
  bool _devHolding = false;
  double _devHoldProgress = 0;

  /// 设置分类导航锚点（animated 滑动指示条测量用；key 为分类）。
  final Map<SettingsCategory, GlobalKey> _catKeys = {};

  /// 分类列表容器锚点（指示条坐标参照系）。
  final GlobalKey _catHostKey = GlobalKey();

  /// 滑动指示条当前位置（相对分类列表容器；与侧边栏 animated 模式同语义）。
  double _catIndicatorLeft = 0;
  double _catIndicatorTop = 0;
  double _catIndicatorHeight = 0;
  bool _catIndicatorReady = false;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  void _setVersion(String version) {
    setState(() => _version = version);
  }

  void _setDevHoldActive(bool active, {double progress = 0}) {
    setState(() {
      _devHolding = active;
      _devHoldProgress = progress;
    });
  }

  void _setDevHoldProgress(double progress) {
    setState(() => _devHoldProgress = progress);
  }

  void _setCategory(SettingsCategory category) {
    setState(() => _category = category);
  }

  void _setQuery(String query) {
    setState(() => _query = query);
  }

  void _clearQuery() {
    _searchCtrl.clear();
    setState(() => _query = '');
  }

  void _setCategoryIndicator(double left, double top, double height) {
    setState(() {
      _catIndicatorLeft = left;
      _catIndicatorTop = top;
      _catIndicatorHeight = height;
      _catIndicatorReady = true;
    });
  }

  @override
  Widget build(BuildContext context) => _buildSettingsDialog(context);
}
