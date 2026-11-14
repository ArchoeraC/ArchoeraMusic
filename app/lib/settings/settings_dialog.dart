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

import 'dart:async' show Timer, unawaited;
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../easter_egg/easter_egg.dart';
import '../stores/app_prefs.dart';
import '../theme/app_theme.dart';
import '../utils/app_version.dart';
import '../widgets/common/anim.dart';
import '../widgets/common/glass_surface.dart';
import '../widgets/common/ink_clip.dart';
import '../widgets/common/smooth_wheel_scroll_controller.dart';
import '../widgets/common/toast.dart';
import '../widgets/layout/side_bar/nav_styles/sidebar_nav_style.dart';
import '../widgets/layout/side_bar/nav_styles/sidebar_nav_style_registry.dart';
import 'cache_section.dart';
import 'history_section.dart';
import 'scans_section.dart';
import 'search_section.dart';
import 'security_section.dart';
import 'settings_anchors.dart';
import 'settings_categories.dart';
import '../services/shortcuts/shortcut_action.dart';
import 'settings_sections.dart';
import 'streaming_server_list.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';

export 'settings_categories.dart';

part 'settings/settings_dialog_actions.dart';
part 'settings/settings_dialog_view.dart';
part 'settings/settings_search_index.g.dart';

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

  /// 设置项标题（同时作为滚动/高亮锚点，与 [SettingsAnchor] 的 label 一致）。
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

class _SettingsDialogState extends ConsumerState<SettingsDialog>
    with SingleTickerProviderStateMixin {
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

  /// 右侧内容区锚点（搜索跳转的高亮框用它做坐标参照系）。
  final GlobalKey _contentHostKey = GlobalKey();

  /// 右侧内容滚动控制（切分类回顶 / 搜索跳转定位用）。
  final ScrollController _contentScrollCtrl = SmoothWheelScrollController();

  /// 搜索结果滚动控制（滚轮 / 触控板与内容区同款弹簧跟随）。
  final ScrollController _searchScrollCtrl = SmoothWheelScrollController();

  /// 左侧分类列表滚动控制（同上）。
  final ScrollController _catScrollCtrl = SmoothWheelScrollController();

  /// 「千万别点」入口是否已解锁：搜索框输入暗号后置位，仅本次弹窗内有效。
  bool _eggUnlocked = false;

  /// 搜索跳转后的「闪几下」高亮（相对内容区的位置）。
  Rect? _flashRect;
  late final AnimationController _flashCtrl;

  /// 高亮脉冲次数与总时长。
  static const int _flashPulses = 3;
  static const Duration _flashDuration = Duration(milliseconds: 1300);

  @override
  void initState() {
    super.initState();
    _flashCtrl = AnimationController(vsync: this, duration: _flashDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() => _flashRect = null);
        }
      });
    _loadVersion();
  }

  @override
  void dispose() {
    _flashCtrl.dispose();
    _searchCtrl.dispose();
    _contentScrollCtrl.dispose();
    _searchScrollCtrl.dispose();
    _catScrollCtrl.dispose();
    _devHoldTimer?.cancel();
    super.dispose();
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
    // 切分类即取消上一轮高亮（它的坐标已无意义），并把内容区回到顶部：
    // 否则新分类会继承上一个分类的滚动偏移。
    _flashCtrl.stop();
    if (_contentScrollCtrl.hasClients) _contentScrollCtrl.jumpTo(0);
    setState(() {
      _category = category;
      _flashRect = null;
    });
  }

  void _setQuery(String query) {
    // 精确输入暗号才解锁「千万别点」；无提示、无 toast、不写入任何偏好。
    final unlock = query.trim().toLowerCase() == kEasterEggUnlockQuery;
    setState(() {
      _query = query;
      if (unlock) _eggUnlocked = true;
    });
  }

  void _clearQuery() {
    _searchCtrl.clear();
    setState(() => _query = '');
  }

  /// 搜索命中：切到所属分类 → 滚到对应设置行 → 闪几下高亮。
  void _jumpToSearchEntry(_SearchEntry entry) {
    _setCategory(entry.category);
    _clearQuery();
    final label = entry.title;
    // 新分类内容要到下一帧才构建/布局，先等一帧再测量位置。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealSetting(label);
    });
  }

  /// 定位 [label] 对应的设置行；内容可能异步挂载（服务器列表等），少量帧重试。
  void _revealSetting(String label, {int attempt = 0}) {
    if (!mounted) return;
    final target = settingsAnchors.lookup(label);
    if (target == null) {
      if (attempt >= 8) return;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _revealSetting(label, attempt: attempt + 1),
      );
      return;
    }
    unawaited(_scrollToAndFlash(target));
  }

  Future<void> _scrollToAndFlash(BuildContext target) async {
    // 滚到视口上方 18% 处（留出上下文），再在落点闪高亮。
    await Scrollable.ensureVisible(
      target,
      alignment: 0.18,
      duration: animDuration(context, const Duration(milliseconds: 320)),
      curve: Curves.easeOutCubic,
    );
    if (!mounted || !target.mounted) return;
    _startFlash(target);
  }

  /// 在目标行位置播放高亮脉冲（[SettingsDialog] 关闭或无尺寸时静默跳过）。
  void _startFlash(BuildContext target) {
    final host = _contentHostKey.currentContext?.findRenderObject();
    final box = target.findRenderObject();
    if (host is! RenderBox || box is! RenderBox || !box.hasSize) return;
    final topLeft = host.globalToLocal(box.localToGlobal(Offset.zero));
    setState(() => _flashRect = topLeft & box.size);
    _flashCtrl.forward(from: 0);
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
