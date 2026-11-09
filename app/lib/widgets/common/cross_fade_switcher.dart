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
    setState(() {
      _outgoing = null;
      _outgoingKey = null;
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
          children: [
            if (outgoing != null)
              Opacity(
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
