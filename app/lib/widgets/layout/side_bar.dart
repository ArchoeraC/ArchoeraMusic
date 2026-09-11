// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../stores/app_prefs.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import 'app_logo.dart';
import '../common/anim.dart';
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

/// 侧边栏（对齐原项目 SideBar.vue + SMenu 观感，独立设计体系）。
///
/// 导航项交互（对齐 SMenu default 模式）：
///  - 选中态：`primary 10%` 背景 + 主色文字 + 左侧 3px 圆角指示条；
///  - 悬浮态：`onSurface 5%` 背景；
///  - Logo 点击回首页（对齐 SideBarLogo.vue，hover 轻微放大）。
///
/// 折叠状态 / 导航高亮动效来自设置（appearance.sidebarCollapsed /
/// appearance.sidebarNavStyle，对齐原版）：
///  - collapsed：侧边栏折叠为图标模式（宽度 240 → 64）；
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

class _SideBarState extends ConsumerState<SideBar> {
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

  List<(String, List<_NavItem>)> _navGroups(AppLocalizations l10n) {
    // 开发者模式关闭时隐藏「下载」入口（避免纠纷；设置-关于长按版本开启）
    final devMode = ref.read(appPrefsProvider).developerMode;
    return [
      (
        l10n.sidebarGroupMusic,
        [
          _NavItem(0, l10n.sidebarHome, EtaIcons.homeOutline, EtaIcons.home),
          _NavItem(
            1,
            l10n.sidebarLibrary,
            EtaIcons.music2Outline,
            EtaIcons.music2,
          ),
          _NavItem(7, l10n.sidebarStreaming, EtaIcons.serverOutline, EtaIcons.server),
        ],
      ),
      (
        l10n.sidebarGroupPersonal,
        [
          _NavItem(
            2,
            l10n.sidebarLiked,
            EtaIcons.heartOutline,
            EtaIcons.heart,
          ),
          _NavItem(3, l10n.sidebarFavorites, EtaIcons.starOutline, EtaIcons.star),
          _NavItem(4, l10n.sidebarHistory, EtaIcons.history, EtaIcons.history),
          if (devMode)
            _NavItem(
              5,
              l10n.sidebarDownload,
              EtaIcons.downloadOutline,
              EtaIcons.download,
            ),
        ],
      ),
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
    if (ref.read(appPrefsProvider).sidebarNavStyle != 'animated') return;
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
