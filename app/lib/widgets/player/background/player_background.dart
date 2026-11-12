// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 全屏播放器背景。
///
/// 背景样式走注册表（[playerBackgrounds]），模块位于 `styles/`：
/// - `gradient`：主题主色 → 播放器底色的对角渐变（默认，兜底）；
/// - `blur`：封面重度模糊背景（`blur(45px) saturate(1.2)` + 放大 + 压暗）；
/// - `solid`：深色纯色；
/// - `ripple`：模糊封面 + 水纹折射（`RippleBackground` 叠加其上）；
/// - `fluid`：流体背景（`FluidBackground`，对齐上游 AMLL `MeshGradientRenderer`）；
/// - `coverTone`：封面主色压暗/提亮的低对比对角渐变。
///
/// 切换背景样式时通过 [CrossFadeSwitcher] 做 200ms 交叉淡化（对齐封面
/// `fade` 动效），不再硬切；`blur` / `ripple` 内部的切歌交叉淡化保持不变。
/// 无封面时大部分样式回退主题渐变。
///
/// 水纹 / 流体需要先解码封面、烘焙纹理与位移网格（「采样参数」）。在这之前
/// 先铺一层**模糊封面缩略图**（对齐 SPlayer-Next `PlayerBackground.vue` 的
/// `.bg-blur-wrap` 预览层），重效果上报首帧可绘制后再淡出，避免进入播放页时
/// 露出纯底色（发黑）。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/render/quality_governor.dart';
import '../../../services/render/render_quality_service.dart';
import '../../../stores/app_prefs.dart';
import '../../common/anim.dart';
import '../../common/cross_fade_switcher.dart';
import 'blurred_cover.dart';
import 'cover_tone_background.dart';
import 'player_background_registry.dart';
import 'player_background_style.dart';

/// 预览层淡出时长（重效果首帧就绪后）。
const Duration kPlayerBackgroundPreviewFade = Duration(milliseconds: 250);

/// 预览层模糊封面的烘焙长边（物理像素）。
///
/// 预览只在进入动画 / 重效果初始化期间出现，本身要整屏高斯；降到 512 后
/// 烘焙成本约为全屏 1/10，而 σ=45 的模糊放大后肉眼几乎无差，避免在转场
/// 期间卡一帧。正式 `blur` 样式仍用 [kBlurredCoverMaxBakeSide]。
const int kPlayerBackgroundPreviewBakeSide = 512;

/// 全屏播放器背景。[cover] 为当前曲目封面地址；[playing] 透传给水纹动画。
///
/// [active] 控制水纹 / 流体等**重效果**是否已经挂载：路由进入动画期间传
/// false，只渲染轻量预览层（模糊封面缩略图 + 主题渐变），动画结束后传 true，
/// 重效果再挂载并在就绪后淡入。这样进入播放页时不会再露出底色（对齐
/// SPlayer-Next `PlayerBackground.vue` 的 `visible` / `active` 分层：预览
/// 即时可见，流体渲染器稍后再建，就绪前一直由预览铺底）。
class PlayerBackground extends ConsumerStatefulWidget {
  const PlayerBackground({
    super.key,
    this.cover,
    this.playing = true,
    this.active = true,
    this.paused = false,
  });

  final String? cover;
  final bool playing;

  /// 重效果（水纹 / 流体）是否已允许挂载；轻量样式不受影响。
  final bool active;

  /// 退出动画期间暂停重效果动画（保留最后一帧），减少收起时的逐帧开销。
  final bool paused;

  @override
  ConsumerState<PlayerBackground> createState() => _PlayerBackgroundState();
}

class _PlayerBackgroundState extends ConsumerState<PlayerBackground> {
  /// 重效果是否已真正挂载。路由动画结束后再延迟两帧，与歌词块 / 频谱的
  /// 首帧构建错开（对齐 SPlayer-Next 的 `visualizerMounted` 双 rAF），避免
  /// 转场结束的同一帧里同时做歌词布局 + 流体网格烘焙。
  bool _heavyMounted = false;

  /// 是否已排队等待挂载重效果（防重复 post-frame）。
  bool _heavyMountScheduled = false;

  /// 当前重效果是否已上报首帧可绘制（水纹封面已解码 / 流体状态已烘焙）。
  bool _heavyReady = false;

  /// 预览层是否已淡出并从树上移除（避免长期叠加两套背景合成层）。
  bool _previewDismissed = false;

  /// 最近一次构建的样式 id：切换样式时重效果会重建，预览状态随之重置。
  String? _styleId;

  /// 路由动画结束后延迟两帧再挂载重效果，给歌词块 / 频谱的首次构建让出帧。
  void _scheduleHeavyMount() {
    if (_heavyMountScheduled || _heavyMounted || widget.paused) return;
    _heavyMountScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _heavyMountScheduled = false;
        if (!widget.active || widget.paused) return;
        setState(() => _heavyMounted = true);
      });
    });
  }

  void _onHeavyReady(String styleId) {
    // 旧样式的重效果可能在切样式后仍有迟到的 post-frame 回调：用样式 id
    // 防止它把新样式的预览层提前淡出。
    if (!mounted || _heavyReady || styleId != _styleId) return;
    setState(() => _heavyReady = true);
  }

  void _onPreviewFadeEnd(String styleId) {
    if (!mounted || !_heavyReady || styleId != _styleId) return;
    setState(() => _previewDismissed = true);
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(appPrefsProvider);
    // 自适应画质仅在偏好开启且 Governor 已降档时生效；否则 renderScale=1.0
    // 与省略该参数逐字节一致（见 RippleBackground.renderScale）。
    final qualityTier = ref.watch(renderQualityProvider);
    final adaptiveScale =
        prefs.adaptiveRenderQuality && qualityTier != RenderQualityTier.full
        ? renderScaleForTier(qualityTier)
        : 1.0;
    // 手动「动态层降分辨率」（仅 CPU 回退生效）与自适应画质取更激进者。
    final renderScale = prefs.rippleLowRes
        ? math.min(rippleLowResScale, adaptiveScale)
        : adaptiveScale;
    final gradient = DecoratedBox(
      decoration: BoxDecoration(
        gradient: playerDefaultBackgroundGradient(context),
      ),
    );
    final cover = widget.cover;
    final hasCover = cover != null && cover.isNotEmpty;
    final style = playerBackgroundFor(prefs.playerBgType);
    if (_styleId != style.id) {
      _styleId = style.id;
      _heavyReady = false;
      _previewDismissed = false;
    }
    final animate = !prefs.performanceMode && !widget.paused;
    final ctx = PlayerBackgroundContext(
      cover: cover,
      playing: widget.playing,
      hasCover: hasCover,
      gradient: gradient,
      onReady: () => _onHeavyReady(style.id),
      ripple: RippleBackgroundConfig(
        speed: prefs.playerBgRippleSpeed,
        animate: animate,
        useShader: prefs.rippleShaderEnabled,
        damageClippedDynamic: prefs.rippleDamageClip,
        renderScale: renderScale,
      ),
      fluid: FluidBackgroundConfig(
        animate: animate,
        flowSpeed: prefs.playerBgFlowSpeed,
        // 自适应画质降档时同样降流体渲染比例（其内部夹到 0.25~2）。
        renderScale: (prefs.playerBgRenderScale * adaptiveScale).clamp(
          0.25,
          2.0,
        ),
        fps: prefs.playerBgFps,
        freezeOnPause: prefs.playerBgFreezeOnPause,
        beat: prefs.playerBgBeat,
      ),
    );
    final needsPreview = hasCover && style.needsPreview;
    final Widget child;
    if (needsPreview) {
      // 重效果样式：底层是「预览期用主题渐变、就绪后换成重效果」，顶层始终
      // 是同一位置的模糊封面预览层。两层结构在 active 翻转时保持稳定，
      // BlurredCover 不会被重建（不会重新解码 / 重新烘焙）。
      if (widget.active) _scheduleHeavyMount();
      final mountHeavy = widget.active && _heavyMounted;
      child = Stack(
        fit: StackFit.expand,
        children: [
          mountHeavy ? style.build(context, ctx) : gradient,
          if (!_previewDismissed)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _heavyReady ? 0 : 1,
                  duration: animDuration(context, kPlayerBackgroundPreviewFade),
                  curve: Curves.easeOut,
                  onEnd: () => _onPreviewFadeEnd(style.id),
                  child: BlurredCover(
                    cover: cover,
                    maxBakeSide: kPlayerBackgroundPreviewBakeSide,
                  ),
                ),
              ),
            ),
        ],
      );
    } else {
      // 轻量样式构建即最终态，不需要预览门控。
      child = style.build(context, ctx);
    }
    return CrossFadeSwitcher(switchKey: style.id, child: child);
  }
}
