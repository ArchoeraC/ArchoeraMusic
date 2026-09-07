// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../player/s_controls.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

/// 搜索页错误态（带重试）。
class SearchErrorState extends StatelessWidget {
  const SearchErrorState({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(EtaIcons.alertOutline, size: 56, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(l10n.pageSearchFailed, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            SButton(
              label: l10n.commonRetry,
              icon: EtaIcons.refresh,
              variant: SButtonVariant.secondary,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}
