// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 通用双层交叉淡化（crossfade）切换器。
///
/// [switchKey] 变化时，旧 child 淡出、新 child 同时淡入，过渡期间两层叠加，
/// 中间不会露出背景/占位；只改变透明度，不做位移或缩放。默认参数对齐
/// SPlayer-Next `SImg.vue` 的 `transition-opacity duration-200`。
///
/// 用 [KeyedSubtree] 保留两层各自的元素状态；系统关闭动画时直接换图。
library;

import 'package:material_ui/material_ui.dart';

import 'anim.dart';

class CrossFadeSwitcher extends StatefulWidget {
  const CrossFadeSwitcher({
    super.key,
    required this.switchKey,
    required this.child,
    this.duration = const Duration(milliseconds: 200),
    this.curve = Curves.ease,
  });

  /// 切换身份；变化时触发交叉淡化。
  final Object switchKey;

  final Widget child;

  /// 交叉淡化时长（性能模式自动归零）。
  final Duration duration;

  /// 两层共用的透明度曲线。
  final Curve curve;

  @override
  State<CrossFadeSwitcher> createState() => _CrossFadeSwitcherState();
}

class _CrossFadeSwitcherState extends State<CrossFadeSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  Widget _shown = const SizedBox.shrink();

  /// 正在离场的旧 child（无过渡时为 null）。
  Widget? _outgoing;

  /// [_outgoing] 对应的切换身份；用 key 让旧层在 Stack 中保持元素状态。
  Object? _outgoingKey;

  @override
  void initState() {
    super.initState();
    _shown = widget.child;
    _ctrl = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(CrossFadeSwitcher old) {
    super.didUpdateWidget(old);
    if (widget.switchKey == old.switchKey) return;
    _ctrl.stop();
    if (noAnim(context)) {
      _outgoing = null;
      _outgoingKey = null;
      _shown = widget.child;
      return;
    }
    _outgoing = _shown;
    _outgoingKey = old.switchKey;
    _shown = widget.child;
    _ctrl.duration = animDuration(context, widget.duration);
    _ctrl.forward(from: 0);
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _outgoing == null) return;
    // 交叉淡化结束：释放旧 child，后续直接渲染新 child。
    // 同步 `_shown`：过渡期间 child 可能已随状态更新（同一 switchKey 下重建），
    // 不刷新会让下一次切换把「旧相位的过期快照」当作离场层。
    setState(() {
      _outgoing = null;
      _outgoingKey = null;
      _shown = widget.child;
    });
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
        final outgoing = _outgoing;
        final t = outgoing == null ? 1.0 : widget.curve.transform(_ctrl.value);
        return Stack(
          // 旧/新 child 的尺寸可能不同（歌名/歌手长度不同）：Stack 取两者最大
          // 尺寸后，必须让每层居中，否则较窄的旧封面会相对居中位置左右/上下
          // 偏移，看起来像“上一首的封面和信息跳了一下”。
          alignment: Alignment.center,
          fit: StackFit.passthrough,
          // 播放页布局切换时共享元素会临时飞出自己的槽位，不能在这里裁切。
          clipBehavior: Clip.none,
          children: [
            // 两层都用**稳定 key**：离场层结束时会从 children 中移除，若两
            // 层都是 keyless，Flutter 会按**下标**复用元素——新层直接顶替
            // 旧层的元素槽，其 child 的 KeyedSubtree key 又不同，于是整棵
            // 子树（列表滚动位置、输入框状态…）被重建。带 key 后移除离场层
            // 时按 key 复用当前层，过渡结束不会重置内容。
            if (outgoing != null)
              Opacity(
                key: const ValueKey('crossfade.out'),
                opacity: (1 - t).clamp(0.0, 1.0),
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: KeyedSubtree(
                      key: ValueKey(_outgoingKey),
                      child: outgoing,
                    ),
                  ),
                ),
              ),
            Opacity(
              key: const ValueKey('crossfade.in'),
              opacity: t.clamp(0.0, 1.0),
              child: KeyedSubtree(
                key: ValueKey(widget.switchKey),
                child: outgoing == null ? widget.child : _shown,
              ),
            ),
          ],
        );
      },
    );
  }
}
