import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'widgets/nav_header.dart';
import 'widgets/player_bar.dart';
import 'widgets/side_bar.dart';

/// 应用壳（对齐原项目 MainLayout.vue）：
/// 左侧 SideBar（可折叠分组导航）+ 右侧（顶部 NavHeader + 页面区）
/// + 底部 PlayerBar（常驻播放条）。
///
/// 页面区切换带 220ms 淡入（对齐原版 RouterView out-in 过渡；
/// 侧边栏分支为 IndexedStack 保持状态，故用轻量淡入而非整页转场）。
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Row(
        children: [
          SideBar(navigationShell: navigationShell),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                const NavHeader(),
                const Divider(height: 1),
                Expanded(
                  child: _BranchFade(
                    index: navigationShell.currentIndex,
                    child: navigationShell,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: const PlayerBar(),
    );
  }
}

/// 侧边栏分支切换淡入（keyed 淡入：切换分支时从透明快速恢复）。
class _BranchFade extends StatefulWidget {
  const _BranchFade({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_BranchFade> createState() => _BranchFadeState();
}

class _BranchFadeState extends State<_BranchFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );

  @override
  void didUpdateWidget(covariant _BranchFade old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
      child: widget.child,
    );
  }
}
