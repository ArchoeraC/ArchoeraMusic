/// 全屏播放器封面块（拆分自 player_page.dart 的 `_buildCoverBlock`）。
///
/// 封面大图 + 下方曲名/副标题（对齐原项目 PlayerData）：
/// - 缩放：播放 1.0 / 暂停 0.9（500ms 弹性过渡，对齐原版 scale-100/90）；
/// - 节拍脉冲：设置开启时鼓点命中轻微放大回弹（[pulse] 动画值驱动，
///   峰值随 [beatStrength] 区分——鼓点越猛缩放越明显）。
library;

import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../services/netease/track.dart';
import '../common/anim.dart';
import '../list/cover_image.dart';

/// 全屏播放器封面块（无状态；脉冲动画由页面持有，本组件只消费动画值）。
class PlayerCoverBlock extends StatelessWidget {
  const PlayerCoverBlock({
    super.key,
    required this.size,
    required this.current,
    required this.hasContent,
    required this.title,
    required this.subtitle,
    required this.playing,
    required this.pulse,
    required this.beatStrength,
    required this.l10n,
  });

  final double size;

  /// 当前曲目（null = 未播放）。
  final Track? current;

  /// 有内容 = 引擎源或在播/恢复的队列（决定占位文案）。
  final bool hasContent;

  final String? title;
  final String? subtitle;
  final bool playing;

  /// 节拍脉冲动画值（0~1；无脉冲时为 0）。
  final Animation<double> pulse;

  /// 最近一次脉冲强度（0~1），决定缩放峰值。
  final double beatStrength;

  final AppLocalizations l10n;

  /// 节拍脉冲增量：0→0.5 冲至峰值，0.5→1 回落到 0。峰值随脉冲强度
  /// 区分（[beatStrength] 0~1）：弱脉冲（~0.25）≈0.6%，强脉冲（1.0）
  /// ≈2.4%——鼓点越猛缩放越明显，高频合成音瞬态也有小幅脉冲。
  double _pulseDelta(double t) {
    final peak = 0.002 + 0.022 * beatStrength;
    if (t <= 0.5) return peak * (t / 0.5);
    return peak * (1 - (t - 0.5) / 0.5);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final cover = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 32,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: CoverImage(
        cover: current?.cover,
        width: size,
        height: size,
        radius: 24,
        iconSize: 110,
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedScale(
          scale: playing ? 1.0 : 0.9,
          duration: animDuration(context, const Duration(milliseconds: 500)),
          curve: Curves.easeOutBack,
          child: AnimatedBuilder(
            animation: pulse,
            builder: (context, child) => Transform.scale(
              scale: 1 + _pulseDelta(pulse.value),
              child: child,
            ),
            child: cover,
          ),
        ),
        const SizedBox(height: 20),
        // 曲名（标题缺失时显示占位，不回退 source 的本地绝对路径/在线 URL）
        Text(
          hasContent
              ? (title ?? l10n.playerBarUntitled)
              : l10n.playerPageNotPlaying,
          style: theme.textTheme.titleLarge,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        // 副标题（歌手等）
        Text(
          hasContent ? (subtitle ?? '') : l10n.playerPageLoadHint,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
