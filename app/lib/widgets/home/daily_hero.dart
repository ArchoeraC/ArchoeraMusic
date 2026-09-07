// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import '../player/s_controls.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

/// 首页每日推荐横幅（渐变背景 + 大按钮）。
class HomeDailyHero extends StatelessWidget {
  const HomeDailyHero({
    super.key,
    required this.loggedIn,
    required this.title,
    required this.subtitleLoggedIn,
    required this.subtitleLoginHint,
    required this.playLabel,
    required this.loginLabel,
    required this.onPlay,
  });

  final bool loggedIn;
  final String title;
  final String subtitleLoggedIn;
  final String subtitleLoginHint;
  final String playLabel;
  final String loginLabel;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      height: 168,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withValues(alpha: 0.28),
            scheme.primaryContainer.withValues(alpha: 0.45),
            scheme.surfaceContainerHigh,
          ],
          stops: const [0, 0.55, 1],
        ),
        border: Border.all(
          color: scheme.primary.withValues(alpha: 0.2),
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: 28,
            top: 8,
            child: Icon(
              EtaIcons.music,
              size: 96,
              color: scheme.primary.withValues(alpha: 0.08),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  loggedIn ? subtitleLoggedIn : subtitleLoginHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                SButton(
                  label: loggedIn ? playLabel : loginLabel,
                  icon: loggedIn
                      ? EtaIcons.play
                      : EtaIcons.entrance,
                  variant: SButtonVariant.primary,
                  onPressed: onPlay,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
