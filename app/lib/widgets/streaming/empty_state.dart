import 'package:flutter/material.dart';

import '../player/s_controls.dart';

/// 空态 / 错误态通用组件。
class StreamingEmptyState extends StatelessWidget {
  const StreamingEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.subtitleError = false,
    this.buttonLabel,
    this.buttonIcon = Icons.link,
    this.buttonLoading = false,
    this.onButton,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool subtitleError;
  final String? buttonLabel;
  final IconData buttonIcon;
  final bool buttonLoading;
  final VoidCallback? onButton;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: scheme.onSurfaceVariant.withValues(alpha: 0.3)),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: subtitleError
                      ? scheme.error
                      : scheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
            ],
            if (buttonLabel != null) ...[
              const SizedBox(height: 16),
              SButton(
                label: buttonLabel!,
                icon: buttonIcon,
                variant: SButtonVariant.primary,
                size: SButtonSize.medium,
                loading: buttonLoading,
                onPressed: onButton,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
