// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../player_cover.dart';

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
  final Track? current;
  final bool hasContent;
  final String? title;
  final String? subtitle;
  final bool playing;
  final Animation<double> pulse;
  final double beatStrength;
  final AppLocalizations l10n;

  double _pulseDelta(double t) {
    final peak = 0.002 + 0.022 * beatStrength;
    if (t <= 0.5) return peak * (t / 0.5);
    return peak * (1 - (t - 0.5) / 0.5);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
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
            child: _PlayerCoverCard(
              size: size,
              cover: current?.cover,
              colorScheme: colorScheme,
            ),
          ),
        ),
        const SizedBox(height: 20),
        _PlayerCoverMeta(
          hasContent: hasContent,
          title: title,
          subtitle: subtitle,
          l10n: l10n,
          theme: theme,
          colorScheme: colorScheme,
        ),
      ],
    );
  }
}

class _PlayerCoverCard extends StatelessWidget {
  const _PlayerCoverCard({
    required this.size,
    required this.cover,
    required this.colorScheme,
  });

  final double size;
  final String? cover;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Container(
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
        cover: cover,
        width: size,
        height: size,
        radius: 24,
        iconSize: 110,
      ),
    );
  }
}

class _PlayerCoverMeta extends StatelessWidget {
  const _PlayerCoverMeta({
    required this.hasContent,
    required this.title,
    required this.subtitle,
    required this.l10n,
    required this.theme,
    required this.colorScheme,
  });

  final bool hasContent;
  final String? title;
  final String? subtitle;
  final AppLocalizations l10n;
  final ThemeData theme;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
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
