import 'package:flutter/material.dart';

/// 封面切换动效（对齐原项目 FullPlayer/index.vue 的封面 Transition）：
///
/// 切歌（封面 [coverKey] 变化）时旧封面先离场、新封面再入场（Vue
/// `mode="out-in"`，两段动画不重叠）。样式跟随偏好：
/// - scale（默认）：±10px 微位移 + 淡入淡出（对齐 scale-switch）；
/// - slide：全幅滑动（对齐 slide-edge），方向跟随播放顺序：下一首
///   新封面从右进、旧封面向左出；上一首相反。
///
/// 时长/曲线对齐原版：scale 离场 0.2s ease / 入场 0.35s easeOutExpo；
/// slide 离场 0.35s ease / 入场 0.4s easeOutExpo
/// （`cubic-bezier(0.16,1,0.3,1)` 即 Flutter [Curves.easeOutExpo]）。
class CoverSwitcher extends StatefulWidget {
  const CoverSwitcher({
    super.key,
    required this.coverKey,
    required this.slide,
    required this.next,
    required this.child,
  });

  /// 封面身份（切歌即变化，触发 out-in 动效）。
  final Object coverKey;

  /// 滑动样式开关（false = 默认缩放样式）。
  final bool slide;

  /// 切歌方向（true = 下一首，新封面从右进）。
  final bool next;

  final Widget child;

  @override
  State<CoverSwitcher> createState() => _CoverSwitcherState();
}

class _CoverSwitcherState extends State<CoverSwitcher>
    with SingleTickerProviderStateMixin {
  // scale-switch：离场 0.2s ease / 入场 0.35s easeOutExpo（±10px）
  static const _scaleLeaveMs = 200;
  static const _scaleEnterMs = 350;
  // slide-edge：离场 0.35s ease / 入场 0.4s easeOutExpo（±100%）
  static const _slideLeaveMs = 350;
  static const _slideEnterMs = 400;

  late final AnimationController _ctrl;

  /// 当前展示的封面块（离场阶段 = 旧封面；入场/静止 = 新封面）。
  ///
  /// 注意：静止阶段 build 直接渲染 [widget.child]（尺寸/内容实时跟随
  /// 父级 LayoutBuilder 的窗口缩放），[_shown] 仅在切歌动效期间锁定画面
  /// 用——此前把 [_shown] 作为静止态唯一渲染源，窗口缩放时新尺寸的封面
  /// 块被丢弃，封面尺寸被冻结无法跟随窗口动态调整。
  Widget _shown = const SizedBox.shrink();

  /// 是否处于「旧封面离场」阶段（false 且动画中 = 新封面入场）。
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _shown = widget.child;
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _scaleEnterMs),
    )..addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(CoverSwitcher old) {
    super.didUpdateWidget(old);
    // 封面身份变化 → 触发旧封面离场（完成后换新封面入场）
    if (widget.coverKey != old.coverKey) {
      // 性能模式（MediaQuery.disableAnimations）：跳过切歌动效，直接换封面
      if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
        _ctrl.stop();
        _leaving = false;
        _shown = widget.child;
        return;
      }
      _leaving = true;
      _ctrl.duration = Duration(
        milliseconds: widget.slide ? _slideLeaveMs : _scaleLeaveMs,
      );
      _ctrl.forward(from: 0);
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!_leaving) return; // 入场完成 → 静止展示新封面
    // 离场完成 → 换上最新封面入场
    _leaving = false;
    setState(() => _shown = widget.child);
    _ctrl.duration = Duration(
      milliseconds: widget.slide ? _slideEnterMs : _scaleEnterMs,
    );
    _ctrl.forward(from: 0);
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
        final t = _ctrl.value;
        // 位移曲线：离场 ease；入场 easeOutExpo（对齐原版 cubic-bezier）。
        final posT = _leaving
            ? Curves.ease.transform(t)
            : Curves.easeOutExpo.transform(t);
        final opT = Curves.ease.transform(t);
        return LayoutBuilder(
          builder: (context, c) {
            // 位移像素：scale 固定 10px；slide 为块宽度的 100%
            final width = c.maxWidth;
            final double dx;
            final double opacity;
            if (_leaving) {
              // 旧封面滑出（下一首 → 左出；上一首 → 右出）
              final dir = widget.next ? -1.0 : 1.0;
              dx = widget.slide ? dir * width * posT : -10.0 * posT;
              opacity = 1 - opT;
            } else if (_ctrl.isAnimating) {
              // 新封面滑入（下一首 → 右进；上一首 → 左进）
              final dir = widget.next ? 1.0 : -1.0;
              dx = widget.slide ? dir * width * (1 - posT) : 10.0 * (1 - posT);
              opacity = opT;
            } else {
              // 静止：完整展示当前封面
              dx = 0;
              opacity = 1;
            }
            return Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(dx, 0),
                // 静止态直接渲染最新 child（窗口缩放/尺寸变化实时生效）；
                // 动画中锁定 _shown（切歌过渡不因尺寸更新而跳动）。
                child: (!_leaving && !_ctrl.isAnimating) ? widget.child : _shown,
              ),
            );
          },
        );
      },
    );
  }
}
