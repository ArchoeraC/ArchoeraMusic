// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放页布局切换：新布局的真实共享元素从旧位置移动/缩放到自身位置。
///
/// 与 SPlayer-Next 的 View Transitions 对齐，但动画对象是新布局的 live 元素
/// 而不是旧布局截图：
/// 1. 切换时测量旧布局三个 [PlayerSharedElementBoundary] 的矩形；
/// 2. 新布局立即挂载，共享元素先隐藏；布局其余部分保持新布局的最终位置；
/// 3. 首帧布局完成后测量新布局的自然矩形，给它的共享元素施加
///    「自然矩形 ← 当前动画矩形」的位移 + 缩放变换；
/// 4. 动画结束清除变换，元素自然落在新布局位置；旧布局只负责其余 chrome
///    的淡出。
///
/// 这样中间帧看到的是新布局的封面渐隐、新字号歌词和实时滚动，不会出现
/// “旧样式飞到一半”或“新元素提前出现在终点”的错位。目标矩形全部来自
/// 布局实际的 `RenderBox`，不写死屏幕坐标。
library;

import 'package:material_ui/material_ui.dart';

import '../common/anim.dart';
import 'player_shared_elements.dart';

class PlayerLayoutSwitcher extends StatefulWidget {
  const PlayerLayoutSwitcher({
    super.key,
    required this.layoutId,
    required this.child,
    required this.keysForLayout,
    this.duration = kPlayerLayoutTransitionDuration,
  });

  /// 当前布局 id（变化时触发过渡）。
  final String layoutId;

  /// 当前布局子树。
  final Widget child;

  /// 布局 id → 该布局的共享元素边界 key（页面缓存，保证稳定）。
  final PlayerSharedElementKeys Function(String layoutId) keysForLayout;

  /// 过渡时长（性能模式下由 [animDuration] 归零直切）。
  final Duration duration;

  @override
  State<PlayerLayoutSwitcher> createState() => _PlayerLayoutSwitcherState();
}

class _PlayerLayoutSwitcherState extends State<PlayerLayoutSwitcher>
    with SingleTickerProviderStateMixin {
  final GlobalKey _stackKey = GlobalKey();
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1,
  );

  late String _id;
  late Widget _child;

  Widget? _previousChild;
  String? _previousId;
  bool _transitioning = false;
  int _token = 0;

  /// 旧布局各共享元素的矩形（播放页局部坐标）。
  Map<PlayerSharedElement, Rect> _oldRects =
      const <PlayerSharedElement, Rect>{};

  /// 新布局各共享元素的自然矩形（完成布局后测量）。
  Map<PlayerSharedElement, Rect> _naturalRects =
      const <PlayerSharedElement, Rect>{};

  @override
  void initState() {
    super.initState();
    // `late` 字段的初始化表达式是惰性求值的：必须在这里显式取 widget，
    // 否则首次读取发生在 didUpdateWidget 时会拿到**新**布局的 id/child。
    _id = widget.layoutId;
    _child = widget.child;
    _ctrl.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _transitioning && mounted) {
      setState(_finish);
    }
  }

  @override
  void didUpdateWidget(covariant PlayerLayoutSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layoutId == widget.layoutId) {
      // 同一布局：只更新内容，不触发过渡。
      _child = widget.child;
      return;
    }
    // 上一次过渡还没结束就再次切换：直接落位，避免使用半途的矩形。
    if (_transitioning) {
      _ctrl.stop();
      _transitioning = false;
      _ctrl.value = 1;
      _finish();
      _id = widget.layoutId;
      _child = widget.child;
      return;
    }
    final duration = animDuration(context, widget.duration);
    if (duration <= Duration.zero) {
      _id = widget.layoutId;
      _child = widget.child;
      return;
    }

    _oldRects = const <PlayerSharedElement, Rect>{};
    _naturalRects = const <PlayerSharedElement, Rect>{};
    _previousChild = _child;
    _previousId = _id;
    _id = widget.layoutId;
    _child = widget.child;
    _transitioning = true;
    _ctrl.duration = duration;
    _ctrl.value = 0;
    final token = ++_token;
    // 新布局完成首帧布局后测量自然矩形，再开始补间。
    WidgetsBinding.instance.addPostFrameCallback((_) => _start(token));
  }

  Map<PlayerSharedElement, Rect> _measure(PlayerSharedElementKeys keys) {
    final stackBox = _renderBoxOf(_stackKey);
    if (stackBox == null) return const <PlayerSharedElement, Rect>{};
    final rects = <PlayerSharedElement, Rect>{};
    for (final kind in PlayerSharedElement.values) {
      final box = _renderBoxOf(keys[kind]);
      if (box != null) rects[kind] = _rectIn(stackBox, box);
    }
    return rects;
  }

  void _start(int token) {
    if (!mounted || !_transitioning || token != _token) return;
    // 旧布局已在目标槽位完成首帧（可能与切换前是同一个 element，也可能
    // 因槽位移动被重建），以它此刻的实际位置作为动画起点，避免用上一帧
    // 的旧矩形造成首帧跳动。新布局的共享元素此时隐藏但已完成布局。
    final previousId = _previousId;
    final oldRects = previousId == null
        ? const <PlayerSharedElement, Rect>{}
        : _measure(widget.keysForLayout(previousId));
    final natural = _measure(widget.keysForLayout(_id));
    setState(() {
      _oldRects = oldRects;
      _naturalRects = natural;
    });
    _ctrl.forward(from: 0);
  }

  void _finish() {
    _token++;
    _transitioning = false;
    _previousChild = null;
    _previousId = null;
    _oldRects = const <PlayerSharedElement, Rect>{};
    _naturalRects = const <PlayerSharedElement, Rect>{};
  }

  static RenderBox? _renderBoxOf(GlobalKey key) {
    final object = key.currentContext?.findRenderObject();
    return object is RenderBox && object.attached ? object : null;
  }

  static Rect _rectIn(RenderBox ancestor, RenderBox child) {
    final topLeft = ancestor.globalToLocal(child.localToGlobal(Offset.zero));
    return topLeft & child.size;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final raw = _ctrl.value.clamp(0.0, 1.0);
        final eased = kPlayerLayoutTransitionCurve.transform(raw);
        final previous = _previousChild;
        // 旧布局退场。新布局在上层且立即按最终位置排版，旧布局主要用来
        // 补齐新布局透明区域的底色/遮罩，所以让它较快淡出。
        final oldOpacity = _transitioning
            ? (1 - (eased * 1.6).clamp(0.0, 1.0))
            : 0.0;
        // 新布局首帧先隐藏共享元素，等测量完成后再按旧矩形出现。
        final measured = _naturalRects.isNotEmpty;
        final hidingNew = _transitioning && !measured;
        final transforms = _transitioning && measured
            ? <PlayerSharedElement, PlayerSharedElementTransform>{
                for (final entry in _naturalRects.entries)
                  entry.key: PlayerSharedElementTransform(
                    natural: entry.value,
                    animated: Rect.lerp(
                      _oldRects[entry.key] ?? entry.value,
                      entry.value,
                      eased,
                    )!,
                  ),
              }
            : const <PlayerSharedElement, PlayerSharedElementTransform>{};
        return Stack(
          key: _stackKey,
          fit: StackFit.expand,
          children: [
            // 固定两槽：旧布局 / 当前布局。槽位稳定，过渡结束不会搬动
            // 当前布局的 element（避免歌词滚动位置等状态被重建）。
            Positioned.fill(
              child: previous == null
                  ? const SizedBox.shrink()
                  : IgnorePointer(
                      child: TickerMode(
                        enabled: false,
                        child: Opacity(
                          opacity: oldOpacity.clamp(0.0, 1.0),
                          // 共享元素由新布局的 live 元素接管；旧布局只保留
                          // 其余 chrome 参与淡出。
                          child: PlayerSharedElementScope(
                            hidden: measured,
                            child: previous,
                          ),
                        ),
                      ),
                    ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                ignoring: _transitioning,
                child: PlayerSharedElementScope(
                  hidden: hidingNew,
                  transforms: transforms,
                  child: _child,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
