// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../stores/app_prefs.dart';
import '../../easter_egg/mouse_dodge.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import 'app_logo.dart';
import 'side_bar/nav_styles/sidebar_nav_style.dart';
import 'side_bar/nav_styles/sidebar_nav_style_registry.dart';
import '../common/anim.dart';
import '../common/ink_clip.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'side_bar/side_bar_view.dart';

/// 侧边导航项（对应一个壳内分支）。
class _NavItem {
  const _NavItem(this.index, this.label, this.icon, this.selectedIcon);

  final int index;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// 侧边栏折叠 / 展开宽度（逻辑像素）。
const double kSideBarCollapsedWidth = 64;
const double kSideBarExpandedWidth = 240;

/// 侧边栏（对齐原项目 SideBar.vue + SMenu 观感，独立设计体系）。
///
/// 导航项交互（对齐 SMenu default 模式）：
///  - 选中态：`primary 10%` 背景 + 主色文字 + 左侧 3px 圆角指示条；
///  - 悬浮态：`onSurface 5%` 背景；
///  - Logo 点击回首页（对齐 SideBarLogo.vue，hover 轻微放大）。
///
/// 折叠状态 / 导航高亮动效来自设置（appearance.sidebarCollapsed /
/// appearance.sidebarNavStyle，对齐原版）：
///  - collapsed：侧边栏折叠为图标模式（宽度 240 → 64）。折叠/展开过渡为
///    「内容渐隐 → 宽度 linear 推进 160ms → 到位后渐显」（总 240ms，
///    ≤300ms）；内容布局在渐隐结束（不可见）时切换到目标态，规避中间
///    宽度下文字/图标/指示条的半成品布局；
///  - sidebarNavStyle=animated：选中指示条改为容器级滑动高亮
///    （AnimatedPositioned 平滑移动，对齐 SMenu animated 模式）。
///
/// 导航分组（对齐原版 SideBar：只放内容入口，工具入口不上侧边栏）：
/// 音乐：首页/音乐库 · 个人：我喜欢/收藏/历史/下载。
/// 搜索由顶栏搜索框进入（隐藏壳分支）；设置由顶栏齿轮弹窗进入。
class SideBar extends ConsumerStatefulWidget {
  const SideBar({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<SideBar> createState() => _SideBarState();
}

class _SideBarState extends ConsumerState<SideBar>
    with SingleTickerProviderStateMixin {
  /// Logo hover 缩放（对齐 SideBarLogo.vue hover:scale-105）。
  double _logoScale = 1.0;

  /// 导航项位置锚点（animated 指示条测量用；key 为分支 index）。
  final Map<int, GlobalKey> _navKeys = {};

  /// 导航列表容器锚点（指示条坐标参照系）。
  final GlobalKey _navHostKey = GlobalKey();

  /// 滑动指示条当前位置（相对导航容器）。
  /// left 跟随选中项左缘：ListView 自带 horizontal padding，固定 0 会把
  /// 指示条放在高亮背景（从 x=10 开始）的左侧之外。
  double _indicatorLeft = 0;
  double _indicatorTop = 0;
  double _indicatorHeight = 0;
  bool _indicatorReady = false;

  /// 折叠/展开过渡时间轴（总 240ms，≤300ms）：
  ///  - 0–80ms：内容渐隐（同时宽度开始线性推进）；
  ///  - 0–160ms：宽度线性推进到位（折叠 240→64 / 展开 64→240）；
  ///  - 160–240ms：到位后内容渐显（此时内容已按目标布局重建）。
  /// 内容布局在渐隐结束（80ms）时于不可见状态下切换，规避中间宽度
  /// 下文字/图标/指示条的半成品布局。
  static const Duration _collapseTransitionDuration = Duration(
    milliseconds: 240,
  );
  static const int _collapseFadeOutMs = 80;
  static const int _collapseWidthMs = 160;
  static const int _collapseTotalMs = 240;

  late final AnimationController _collapseCtrl;

  /// 当前内容布局使用的折叠态（过渡中途在不可见时切换到目标态）。
  bool _layoutCollapsed = false;

  /// 本次过渡起点的布局 / 目标布局。
  bool _sourceCollapsed = false;
  bool _targetCollapsed = false;

  /// 本次过渡的宽度区间（中断重入时从当前显示宽度继续）。
  double _startWidth = kSideBarExpandedWidth;
  double _targetWidth = kSideBarExpandedWidth;

  /// 本次过渡起点的内容不透明度（中断重入时从当前亮度继续渐隐）。
  double _startOpacity = 1;

  @override
  void initState() {
    super.initState();
    final collapsed = ref.read(appPrefsProvider).sidebarCollapsed;
    _layoutCollapsed = collapsed;
    _sourceCollapsed = collapsed;
    _targetCollapsed = collapsed;
    final width = collapsed ? kSideBarCollapsedWidth : kSideBarExpandedWidth;
    _startWidth = width;
    _targetWidth = width;
    _collapseCtrl =
        AnimationController(vsync: this, duration: _collapseTransitionDuration)
          ..addListener(_onCollapseTick)
          ..addStatusListener(_onCollapseStatus);
  }

  @override
  void dispose() {
    _collapseCtrl.dispose();
    super.dispose();
  }

  /// 过渡已推进的毫秒数（0–240）。
  double get _collapseElapsedMs => _collapseCtrl.value * _collapseTotalMs;

  /// 当前应显示的宽度（0–160ms 线性插值，之后固定在目标宽度）。
  double get _displayWidth {
    final p = (_collapseElapsedMs / _collapseWidthMs).clamp(0.0, 1.0);
    return _startWidth + (_targetWidth - _startWidth) * p;
  }

  /// 当前内容不透明度：渐隐 → 全隐 → 到位后渐显。
  /// 渐隐时长按起点不透明度缩放；宽度始终占 0–160ms，渐显固定 160–240ms。
  double get _contentOpacity {
    final ms = _collapseElapsedMs;
    final fadeOutMs = _collapseFadeOutMs * _startOpacity;
    if (ms < fadeOutMs) return _startOpacity * (1 - ms / fadeOutMs);
    if (ms < _collapseWidthMs) return 0;
    if (ms < _collapseTotalMs) {
      return (ms - _collapseWidthMs) / (_collapseTotalMs - _collapseWidthMs);
    }
    return 1;
  }

  /// 渐隐结束（内容已不可见）时切换内容布局，避免可见的半成品布局。
  void _onCollapseTick() {
    final useTarget = _collapseElapsedMs >= _collapseFadeOutMs * _startOpacity;
    final layout = useTarget ? _targetCollapsed : _sourceCollapsed;
    if (layout != _layoutCollapsed) {
      setState(() => _layoutCollapsed = layout);
    }
  }

  /// 过渡到位：强制一次重建，让 `_updateIndicator` 按最终布局重新测量。
  void _onCollapseStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    setState(() {
      _layoutCollapsed = _targetCollapsed;
      _sourceCollapsed = _targetCollapsed;
      _startOpacity = 1;
    });
  }

  /// 折叠/展开过渡：渐隐 → 宽度线性推进 → 渐显。
  void _animateSidebarCollapse(bool collapsed) {
    if (!mounted) return;
    if (_targetCollapsed == collapsed &&
        !_collapseCtrl.isAnimating &&
        _layoutCollapsed == collapsed) {
      return;
    }
    // 从当前显示宽度 / 亮度继续；中断重入时按起点不透明度缩放渐隐阶段。
    final fromWidth = _displayWidth;
    final fromOpacity = _contentOpacity;
    _collapseCtrl.stop();
    setState(() {
      _sourceCollapsed = _layoutCollapsed;
      _targetCollapsed = collapsed;
      _startWidth = fromWidth;
      _targetWidth = collapsed ? kSideBarCollapsedWidth : kSideBarExpandedWidth;
      _startOpacity = fromOpacity;
      // 指示条随内容一起渐隐；到位后按最终布局重新测量，避免补位滑动。
      _indicatorReady = false;
    });
    _collapseCtrl.duration = animDuration(context, _collapseTransitionDuration);
    _collapseCtrl.forward(from: 0);
  }

  List<(String, List<_NavItem>)> _navGroups(AppLocalizations l10n) {
    final prefs = ref.read(appPrefsProvider);
    // 下载模块（开发者模式 + 独立开关）关闭时隐藏「下载」入口。
    final downloadModule = prefs.downloadModuleEnabled;
    final hidden = prefs.sidebarHiddenKeys;
    // 稳定 key → （分支 index, 文案, 图标, 选中图标）。
    final defs = <String, (int, String, IconData, IconData)>{
      'home': (0, l10n.sidebarHome, EtaIcons.homeOutline, EtaIcons.home),
      'library': (
        1,
        l10n.sidebarLibrary,
        EtaIcons.music2Outline,
        EtaIcons.music2,
      ),
      'streaming': (
        7,
        l10n.sidebarStreaming,
        EtaIcons.serverOutline,
        EtaIcons.server,
      ),
      'liked': (2, l10n.sidebarLiked, EtaIcons.heartOutline, EtaIcons.heart),
      'favorites': (
        3,
        l10n.sidebarFavorites,
        EtaIcons.starOutline,
        EtaIcons.star,
      ),
      'history': (4, l10n.sidebarHistory, EtaIcons.history, EtaIcons.history),
      'download': (
        5,
        l10n.sidebarDownload,
        EtaIcons.downloadOutline,
        EtaIcons.download,
      ),
    };
    const musicKeys = ['home', 'library', 'streaming'];
    const personalKeys = ['liked', 'favorites', 'history', 'download'];

    List<_NavItem> itemsOf(List<String> groupKeys) {
      final out = <_NavItem>[];
      // 按用户自定义顺序遍历（[AppPrefs.sidebarOrder] 已归一化补齐）。
      for (final key in prefs.sidebarOrder) {
        if (!groupKeys.contains(key)) continue;
        if (hidden.contains(key)) continue;
        if (key == 'download' && !downloadModule) continue;
        final d = defs[key];
        if (d == null) continue;
        out.add(_NavItem(d.$1, d.$2, d.$3, d.$4));
      }
      return out;
    }

    final groups = <(String, List<_NavItem>)>[
      (l10n.sidebarGroupMusic, itemsOf(musicKeys)),
      (l10n.sidebarGroupPersonal, itemsOf(personalKeys)),
    ];
    // 分组内项全部隐藏时不渲染空标题。
    return [
      for (final g in groups)
        if (g.$2.isNotEmpty) g,
    ];
  }

  int get _currentIndex => widget.navigationShell.currentIndex;

  void _goBranch(int index) {
    widget.navigationShell.goBranch(
      index,
      // 点击当前分支时回退到初始位置（清栈）
      initialLocation: index == _currentIndex,
    );
  }

  /// 测量选中项在导航容器中的位置，驱动滑动指示条。
  ///
  /// 折叠/展开或切换分支后经 postFrameCallback 调用；位置未变时不做
  /// setState（避免 rebuild → 再测量 的死循环）。
  void _updateIndicator() {
    // 折叠/展开过渡中跳过：过渡结束后再按最终布局重新定位。
    if (_collapseCtrl.isAnimating) return;
    final style = sidebarNavStyleFor(
      ref.read(appPrefsProvider).sidebarNavStyle,
    );
    if (!style.slidingIndicator) return;
    final hostCtx = _navHostKey.currentContext;
    final itemCtx = _navKeys[_currentIndex]?.currentContext;
    if (hostCtx == null || itemCtx == null || !itemCtx.mounted) return;
    final hostBox = hostCtx.findRenderObject() as RenderBox?;
    final itemBox = itemCtx.findRenderObject() as RenderBox?;
    if (hostBox == null || itemBox == null) return;
    final pos = itemBox.localToGlobal(Offset.zero, ancestor: hostBox);
    final left = pos.dx;
    final top = pos.dy;
    final height = itemBox.size.height;
    if (!_indicatorReady ||
        left != _indicatorLeft ||
        top != _indicatorTop ||
        height != _indicatorHeight) {
      setState(() {
        _indicatorLeft = left;
        _indicatorTop = top;
        _indicatorHeight = height;
        _indicatorReady = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) => _buildSideBar(context);

  void _setLogoScale(double value) {
    setState(() => _logoScale = value);
  }
}
