import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../common/anim.dart';

/// 音质切换菜单（对齐 SPlayer-Next 音质档位 + MoeKoeMusic 品质切换交互）。
class QualityMenu extends StatelessWidget {
  const QualityMenu({
    super.key,
    required this.levels,
    required this.current,
    required this.onSelected,
  });

  final List<String> levels;
  final String current;
  final void Function(String) onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return PopupMenuButton<String>(
      tooltip: l10n.playerPageQualityMenu,
      // 性能模式：菜单直出，无淡入/弹出动效
      popUpAnimationStyle: noAnim(context) ? AnimationStyle.noAnimation : null,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final l in levels)
          PopupMenuItem(
            value: l,
            child: Row(
              children: [
                Text(l10nQualityLabel(l10n, l)),
                const Spacer(),
                if (l == current)
                  Icon(Icons.check, size: 16, color: theme.colorScheme.primary),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.tune,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              l10nQualityLabel(l10n, current),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
