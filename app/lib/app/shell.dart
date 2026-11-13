// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/playback/playback_notifier.dart';
import '../services/scanner/library_store.dart';
import '../stores/app_prefs.dart';
import '../stores/player_route_animation.dart';
import '../widgets/common/anim.dart';
import '../widgets/common/fps_monitor.dart';
import '../widgets/layout/nav_header.dart';
import '../widgets/layout/player_bar.dart';
import '../widgets/layout/side_bar.dart';
import '../widgets/common/offstage_when_complete.dart';
import 'appearance_styles/appearance_style_registry.dart';
import 'route_transitions/route_transition_registry.dart';

/// 应用壳（对齐原项目 MainLayout.vue）：
/// 左侧 SideBar（可折叠分组导航）+ 右侧（顶部 NavHeader + 页面区）
/// + 底部 PlayerBar（常驻播放条）。
///
/// 页面区切换带分支转场（对齐原版 RouterView out-in 过渡 + global.css
/// route-fade/slide/zoom；侧边栏分支为 IndexedStack 保持状态，故用轻量
/// 过渡而非整页转场）。
///
/// 图片背景风格（appearanceStyle=image）：整个 body 叠一层封面图
/// （对齐原版 AppBackground.vue：fixed inset-0 + cover + 模糊/缩放 + 暗遮罩）。
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(appPrefsProvider);
    // 图片风格「有效」才渲染背景（无图时回退 solid，对齐原版 effectiveStyle）
    final appearanceStyle = appearanceStyleFor(prefs.appearanceStyle);
    final background = appearanceStyle.buildBackground(context, prefs);
    final floating = prefs.floatingPlayerBar;
    final collapsed = prefs.sidebarCollapsed;
    // 全屏播放器展开时，主壳内容保持原位：不做缩放 / 淡出，只有播放页
    // 自身从下方上滑盖住它。
    //
    // 用**播放页路由自身的动画**判断遮挡完成（经 provider 传入）：该动画由
    // 播放页的 Ticker 逐帧推进；壳层无需自建 Ticker，避免下方路由被 offstage
    // 时动画停摆（0=折叠，1=完全展开）。
    final playerRouteAnim =
        ref.watch(playerRouteAnimationProvider) ??
        const AlwaysStoppedAnimation<double>(0);
    // 播放条可见时，停靠模式给内容底部留白（对齐原版 mb-20），
    // 防止被全宽停靠条遮挡；悬浮模式占满全高（侧边栏可到底）。
    final showBar = ref.watch(
      playbackProvider.select((s) => s.source != null || s.hasQueue),
    );
    // 进入音乐库分支时自动增量扫描（5 分钟内不重复）：indexedStack 页面
    // 常驻，页面 initState 只在首次构建触发，需在壳层监听分支切换。
    if (navigationShell.currentIndex == 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(libraryStoreProvider.notifier).maybeAutoRefresh();
      });
    }
    final content = Row(
      children: [
        SideBar(navigationShell: navigationShell),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            children: [
              const NavHeader(),
              const Divider(height: 1),
              Expanded(
                child: _BranchTransition(
                  index: navigationShell.currentIndex,
                  transition: prefs.routeTransition,
                  child: navigationShell,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    // 播放页完全展开时（`/player` 路由为 opaque:false，壳层仍被绘制），
    // 壳层背景与播放条被播放页整幅不透明背景完全盖住——用 Offstage 停绘
    // （保留状态，返回时无重建闪烁），避免每帧白白重放全屏背景贴图与
    // 播放条（遮挡显式隐藏，见 docs/rendering-reference-research.md D6）。
    Widget occludedWhenPlayerOpen(Widget child) =>
        OffstageWhenComplete(animation: playerRouteAnim, child: child);
    final body = Stack(
      children: [
        if (background != null)
          Positioned.fill(child: occludedWhenPlayerOpen(background)),
        // 内容层（停靠模式且播放条可见时底部让位；悬浮模式占满全高）
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.only(bottom: !floating && showBar ? 82 : 0),
            // 播放页打开/关闭时壳内容不做任何动效，原位保留；完全展开后
            // 只停绘/停 ticker（State 保留），收起即恢复。
            child: occludedWhenPlayerOpen(content),
          ),
        ),
        // 底部播放条（悬浮层，不占布局空间——对齐原版 MainLayout 的
        // fixed 播放条：悬浮模式侧边栏可占满侧边；播放条从侧边栏
        // 右侧开始，避免盖住侧边栏底部）
        // 侧边栏折叠/展开时与宽度动效同步平移（linear，时长一致）。
        AnimatedPositioned(
          duration: animDuration(context, const Duration(milliseconds: 160)),
          curve: Curves.linear,
          left: floating
              ? (collapsed ? kSideBarCollapsedWidth : kSideBarExpandedWidth) + 1
              : 0,
          right: 0,
          bottom: 0,
          child: occludedWhenPlayerOpen(const PlayerBar()),
        ),
        // Dev 模式性能监控（右上角小窗；默认 SizedBox.shrink 零开销）
        const Positioned(top: 10, right: 10, child: FpsMonitorHost()),
      ],
    );
    // 后台节能（最小化/托盘/熄屏）只停帧/降频，不再卸载 UI 子树：
    // 卸载/重建会 churn 渲染资源（表面/图层/驱动缓存只涨不缩），且恢复时
    // 重建成本高于保持挂载。详见 `PowerSaverService`。
    return Scaffold(body: body);
  }
}

/// 侧边栏分支切换转场（对齐原版 route-fade/slide/zoom 的进入动画，
/// out-in 语义下只对进入的新分支做动画）。
///
/// 具体转场实现与参数集中在 `route_transitions/`，此处只按偏好 id 查表：
///  - none：无转场，直接显示；
///  - fade：150ms 淡入（原版进入 0.15s）；
///  - slide：从右侧 +6px 滑入（原版 route-slide 进入 translateX(6px)）；
///  - zoom：从 0.97 放大到 1（原版 route-zoom 进入 scale(0.97)）。
class _BranchTransition extends StatefulWidget {
  const _BranchTransition({
    required this.index,
    required this.transition,
    required this.child,
  });

  final int index;
  final String transition;
  final Widget child;

  @override
  State<_BranchTransition> createState() => _BranchTransitionState();
}

class _BranchTransitionState extends State<_BranchTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: routeTransitionFor(widget.transition).duration,
      value: 1,
    );
  }

  @override
  void didUpdateWidget(covariant _BranchTransition old) {
    super.didUpdateWidget(old);
    final transition = routeTransitionFor(widget.transition);
    if (old.index != widget.index && !transition.isNoop) {
      // 性能模式（MediaQuery.disableAnimations）：跳过分支转场动效
      if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
      _ctrl.duration = transition.duration;
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
    final transition = routeTransitionFor(widget.transition);
    if (transition.isNoop ||
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      return widget.child;
    }
    return transition.build(context, _ctrl, widget.child);
  }
}
