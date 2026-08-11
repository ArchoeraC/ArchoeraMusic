import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../stores/app_prefs.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import 'app_logo.dart';
import '../common/anim.dart';

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
        (l10n.sidebarGroupMusic, [
          _NavItem(0, l10n.sidebarHome, Icons.home_outlined, Icons.home),
          _NavItem(
            1,
            l10n.sidebarLibrary,
            Icons.library_music_outlined,
            Icons.library_music,
          ),
          _NavItem(
            7,
            l10n.sidebarStreaming,
            Icons.dns_outlined,
            Icons.dns,
          ),
        ]),
        (l10n.sidebarGroupPersonal, [
          _NavItem(2, l10n.sidebarLiked, Icons.favorite_outline, Icons.favorite),
          _NavItem(3, l10n.sidebarFavorites, Icons.star_outline, Icons.star),
          _NavItem(4, l10n.sidebarHistory, Icons.history, Icons.history),
          if (devMode)
            _NavItem(5, l10n.sidebarDownload, Icons.download_outlined, Icons.download),
        ]),
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    final prefs = ref.watch(appPrefsProvider);
    final collapsed = prefs.sidebarCollapsed;
    final navStyle = prefs.sidebarNavStyle;
    final animated = navStyle == 'animated';
    final width = collapsed ? 64.0 : 240.0;
    // 布局完成后测量选中项位置（折叠/展开切换后指示条跟随）
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateIndicator());

    return AnimatedContainer(
      duration: animDuration(context, const Duration(milliseconds: 200)),
      curve: Curves.easeOutCubic,
      width: width,
      color: colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          // Logo（对齐 SideBarLogo.vue：点击回首页，hover 放大）
          SizedBox(
            height: 64,
            child: Center(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _logoScale = 1.05),
                onExit: (_) => setState(() => _logoScale = 1.0),
                child: Tooltip(
                  message: l10n.sidebarBackHome,
                  waitDuration: const Duration(milliseconds: 500),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _goBranch(0),
                    child: TweenAnimationBuilder<double>(
                      duration: animDuration(
                          context, const Duration(milliseconds: 150)),
                      tween: Tween(begin: _logoScale, end: _logoScale),
                      builder: (context, scale, child) =>
                          Transform.scale(scale: scale, child: child),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Logo（白标：完全跟随全局主题对比色——底 primaryContainer、标 onPrimaryContainer）
                          const AppLogo(size: 30),
                          // 折叠时文字淡出（保留宽度占位过渡）
                          AnimatedOpacity(
                            duration: animDuration(
                                context, const Duration(milliseconds: 200)),
                            opacity: collapsed ? 0 : 1,
                            child: AnimatedContainer(
                              duration: animDuration(
                                  context, const Duration(milliseconds: 200)),
                              width: collapsed ? 0 : 110,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 10),
                                child: Text(
                                  'Archoera',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.3,
                                    color: colorScheme.primary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          // 导航菜单（分组）；animated 模式叠一层容器级滑动指示条
          Expanded(
            child: Stack(
              key: _navHostKey,
              children: [
                ListView(
                  padding: EdgeInsets.symmetric(
                    horizontal: collapsed ? 10 : 10,
                    vertical: 8,
                  ),
                  children: [
                    for (final (groupTitle, items) in _navGroups(l10n)) ...[
                      if (!collapsed)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 5),
                          child: Text(
                            groupTitle,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.5,
                              color: colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.6),
                            ),
                          ),
                        )
                      else
                        const SizedBox(height: 12),
                      for (final item in items)
                        _buildNavItem(theme, item, collapsed, animated),
                    ],
                  ],
                ),
                // 滑动高亮指示条（SMenu animated：绝对定位左 3px 圆角主色条，
                // AnimatedPositioned 平滑更新 top/height，对齐 transition-[top,height] duration-250）
                if (animated && _indicatorReady)
                  AnimatedPositioned(
                    duration: animDuration(
                        context, const Duration(milliseconds: 250)),
                    curve: Curves.easeOut,
                    // 对齐 SMenu animated：left 跟随选中项左缘；top/height
                    // 上下各内缩 10px，与静态模式（Positioned top:10/bottom:10）一致
                    left: _indicatorLeft,
                    top: _indicatorTop + 10,
                    height: _indicatorHeight - 20,
                    width: 3,
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          // 折叠开关
          SizedBox(
            height: 48,
            child: IconButton(
              tooltip: collapsed ? l10n.sidebarExpand : l10n.sidebarCollapse,
              onPressed: () => ref
                  .read(appPrefsProvider.notifier)
                  .setSidebar(collapsed: !collapsed),
              icon: Icon(
                collapsed ? Icons.menu_open : Icons.menu_rounded,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(
      ThemeData theme, _NavItem item, bool collapsed, bool animated) {
    final colorScheme = theme.colorScheme;
    final selected = _currentIndex == item.index;
    final foreground = selected ? colorScheme.primary : colorScheme.onSurface;
    // 位置锚点：animated 模式下滑动指示条据此定位。挂在背景容器
    // （AnimatedContainer）上，使测量结果即选中项背景本身的位置与尺寸，
    // top+10 / height-20 即可与静态模式（Positioned top:10/bottom:10）完全对齐。
    final anchor = _navKeys[item.index] ??= GlobalKey();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: AnimatedContainer(
        key: anchor,
        duration: animDuration(context, const Duration(milliseconds: 180)),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primary.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            hoverColor: selected
                ? Colors.transparent
                : colorScheme.onSurface.withValues(alpha: 0.05),
            onTap: () => _goBranch(item.index),
            child: SizedBox(
              height: 40,
              // 内容行需垂直居中：Stack 默认 topStart 对齐会把 20px 高的
              // 内容行顶到 40px 容器顶部（指示条用 Positioned 不受影响）
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 左侧选中指示条（对齐 SMenu default 模式；
                  // animated 模式交给容器级滑动条，此处隐藏）
                  Positioned(
                    left: 0,
                    top: 10,
                    bottom: 10,
                    child: AnimatedContainer(
                      duration: animDuration(
                          context, const Duration(milliseconds: 180)),
                      curve: Curves.easeOut,
                      width: 3,
                      decoration: BoxDecoration(
                        color: !animated && selected
                            ? colorScheme.primary
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // 内容行
                  Row(
                    mainAxisAlignment: collapsed
                        ? MainAxisAlignment.center
                        : MainAxisAlignment.start,
                    children: [
                      if (!collapsed) const SizedBox(width: 12),
                      Icon(
                        selected ? item.selectedIcon : item.icon,
                        size: 19,
                        color: foreground,
                      ),
                      // 折叠时文字淡出（对齐 SMenu opacity 过渡）
                      Expanded(
                        child: AnimatedOpacity(
                          duration: animDuration(
                              context, const Duration(milliseconds: 200)),
                          opacity: collapsed ? 0 : 1,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 12),
                            child: Text(
                              item.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: foreground,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
