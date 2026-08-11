import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../player/s_controls.dart';

/// 未登录引导卡片：图标 + 标题 + 说明 + 登录按钮（按页面传参）。
class LoginGuide extends StatelessWidget {
  const LoginGuide({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.onLogin,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 40),
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: scheme.outline.withValues(alpha: 0.2),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 30,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              description,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            SButton(
              label: l10n.navHeaderQrLogin,
              icon: Icons.qr_code_2,
              variant: SButtonVariant.primary,
              onPressed: onLogin,
            ),
          ],
        ),
      ),
    );
  }
}
