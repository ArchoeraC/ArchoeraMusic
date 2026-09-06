// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../side_bar.dart';

extension _SideBarView on _SideBarState {
  Widget _buildSideBar(BuildContext context) {
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
                onEnter: (_) => _setLogoScale(1.05),
                onExit: (_) => _setLogoScale(1.0),
                child: Tooltip(
                  message: l10n.sidebarBackHome,
                  waitDuration: const Duration(milliseconds: 500),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _goBranch(0),
                    child: TweenAnimationBuilder<double>(
                      duration: animDuration(
                        context,
                        const Duration(milliseconds: 150),
                      ),
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
                              context,
                              const Duration(milliseconds: 200),
                            ),
                            opacity: collapsed ? 0 : 1,
                            child: AnimatedContainer(
                              duration: animDuration(
                                context,
                                const Duration(milliseconds: 200),
                              ),
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
                              color: colorScheme.onSurfaceVariant.withValues(
                                alpha: 0.6,
                              ),
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
                      context,
                      const Duration(milliseconds: 250),
                    ),
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
    ThemeData theme,
    _NavItem item,
    bool collapsed,
    bool animated,
  ) {
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
                        context,
                        const Duration(milliseconds: 180),
                      ),
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
                            context,
                            const Duration(milliseconds: 200),
                          ),
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
