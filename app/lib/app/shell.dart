import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/playback/playback_notifier.dart';
import '../services/scanner/library_store.dart';
import '../stores/app_prefs.dart';
import '../widgets/common/fps_monitor.dart';
import '../widgets/layout/nav_header.dart';
import '../widgets/layout/player_bar.dart';
import '../widgets/layout/side_bar.dart';

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
    final imageStyle =
        prefs.appearanceStyle == 'image' && prefs.backgroundImage != null;
    final floating = prefs.floatingPlayerBar;
    final collapsed = prefs.sidebarCollapsed;
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
    return Scaffold(
      body: Stack(
        children: [
          if (imageStyle) Positioned.fill(child: _AppBackground(prefs: prefs)),
          // 内容层（停靠模式且播放条可见时底部让位；悬浮模式占满全高）
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(bottom: !floating && showBar ? 82 : 0),
              child: content,
            ),
          ),
          // 底部播放条（悬浮层，不占布局空间——对齐原版 MainLayout 的
          // fixed 播放条：悬浮模式侧边栏可占满侧边；播放条从侧边栏
          // 右侧开始，避免盖住侧边栏底部）
          Positioned(
            left: floating ? (collapsed ? 64.0 : 240.0) + 1 : 0,
            right: 0,
            bottom: 0,
            child: const PlayerBar(),
          ),
          // Dev 模式性能监控（右上角小窗；默认 SizedBox.shrink 零开销）
          const Positioned(top: 10, right: 10, child: FpsMonitorHost()),
        ],
      ),
    );
  }
}

/// 图片背景层（对齐原版 AppBackground.vue）：
/// 封面图（cover 裁切）+ 高斯模糊 + 缩放 + 黑色遮罩（dim），忽略指针事件。
class _AppBackground extends StatelessWidget {
  const _AppBackground({required this.prefs});

  final AppPrefs prefs;

  @override
  Widget build(BuildContext context) {
    final path = prefs.backgroundImage;
    if (path == null || path.isEmpty) return const SizedBox.shrink();
    // 背景铺满全屏又带模糊/遮罩，无需原图全分辨率：按屏幕物理尺寸解码，
    // 大壁纸（4K+）可省数 MB 解码位图内存。
    final screen = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final decodeW = (screen.width * dpr).round().clamp(1, 2560);
    final decodeH = (screen.height * dpr).round().clamp(1, 2560);
    Widget image = Image.file(
      File(path),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      cacheWidth: decodeW,
      cacheHeight: decodeH,
      // 文件被移动/删除时静默回退纯色背景（不崩溃）
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
    if (prefs.backgroundBlur > 0) {
      final sigma = prefs.backgroundBlur.toDouble();
      image = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: image,
      );
    }
    if (prefs.backgroundScale != 1) {
      image = Transform.scale(scale: prefs.backgroundScale, child: image);
    }
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          ColoredBox(
            color: Colors.black.withValues(alpha: prefs.backgroundDim),
          ),
        ],
      ),
    );
  }
}

/// 侧边栏分支切换转场（对齐原版 route-fade/slide/zoom 的进入动画，
/// out-in 语义下只对进入的新分支做动画）：
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
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
    value: 1,
  );

  @override
  void didUpdateWidget(covariant _BranchTransition old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index && widget.transition != 'none') {
      // 性能模式（MediaQuery.disableAnimations）：跳过分支转场动效
      if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
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
    if (widget.transition == 'none' ||
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      return widget.child;
    }
    final curved = CurvedAnimation(
      parent: _ctrl,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );
    return switch (widget.transition) {
      'slide' => FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.008, 0),
            end: Offset.zero,
          ).animate(curved),
          child: widget.child,
        ),
      ),
      'zoom' => FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
          child: widget.child,
        ),
      ),
      _ => FadeTransition(opacity: curved, child: widget.child),
    };
  }
}
