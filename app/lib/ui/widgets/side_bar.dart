import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import 'app_logo.dart';

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
  /// 折叠状态（Phase 1 本地态，后续并入设置 appearance.sidebarCollapsed）。
  bool _collapsed = false;

  /// Logo hover 缩放（对齐 SideBarLogo.vue hover:scale-105）。
  double _logoScale = 1.0;

  List<(String, List<_NavItem>)> _navGroups(AppLocalizations l10n) => [
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
      _NavItem(5, l10n.sidebarDownload, Icons.download_outlined, Icons.download),
    ]),
  ];

  int get _currentIndex => widget.navigationShell.currentIndex;

  void _goBranch(int index) {
    widget.navigationShell.goBranch(
      index,
      // 点击当前分支时回退到初始位置（清栈）
      initialLocation: index == _currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    final width = _collapsed ? 64.0 : 240.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
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
                      duration: const Duration(milliseconds: 150),
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
                            duration: const Duration(milliseconds: 200),
                            opacity: _collapsed ? 0 : 1,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: _collapsed ? 0 : 110,
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
          // 导航菜单（分组）
          Expanded(
            child: ListView(
              padding: EdgeInsets.symmetric(
                horizontal: _collapsed ? 10 : 10,
                vertical: 8,
              ),
              children: [
                for (final (groupTitle, items) in _navGroups(l10n)) ...[
                  if (!_collapsed)
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
                  for (final item in items) _buildNavItem(theme, item),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          // 折叠开关
          SizedBox(
            height: 48,
            child: IconButton(
              tooltip: _collapsed ? l10n.sidebarExpand : l10n.sidebarCollapse,
              onPressed: () => setState(() => _collapsed = !_collapsed),
              icon: Icon(
                _collapsed ? Icons.menu_open : Icons.menu_rounded,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(ThemeData theme, _NavItem item) {
    final colorScheme = theme.colorScheme;
    final selected = _currentIndex == item.index;
    final foreground = selected ? colorScheme.primary : colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
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
                  // 左侧选中指示条（对齐 SMenu default 模式）
                  Positioned(
                    left: 0,
                    top: 10,
                    bottom: 10,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      width: 3,
                      decoration: BoxDecoration(
                        color: selected
                            ? colorScheme.primary
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // 内容行
                  Row(
                    mainAxisAlignment: _collapsed
                        ? MainAxisAlignment.center
                        : MainAxisAlignment.start,
                    children: [
                      if (!_collapsed) const SizedBox(width: 12),
                      Icon(
                        selected ? item.selectedIcon : item.icon,
                        size: 19,
                        color: foreground,
                      ),
                      // 折叠时文字淡出（对齐 SMenu opacity 过渡）
                      Expanded(
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 200),
                          opacity: _collapsed ? 0 : 1,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 12),
                            child: Text(
                              item.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: foreground,
                                fontWeight:
                                    selected ? FontWeight.w600 : FontWeight.w400,
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
