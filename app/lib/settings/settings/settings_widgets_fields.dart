// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_widgets.dart';

/// 复制按钮（存储页路径复制，点击写剪贴板并弹成功提示）。
class SettingCopyButton extends StatelessWidget {
  const SettingCopyButton({
    super.key,
    required this.value,
    required this.label,
  });

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      height: 28,
      child: SButton(
        label: l10n.settingsCopy,
        variant: SButtonVariant.ghost,
        size: SButtonSize.small,
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: value));
          if (!context.mounted) return;
          toast(
            l10n.toastCopied(label),
            type: ToastType.success,
            duration: const Duration(milliseconds: 1200),
          );
        },
      ),
    );
  }
}

/// 路径输入卡：图标徽章 + 输入框 + 恢复默认（下载目录 / 文件名模板 /
/// 刮削目录共用）。
class SettingPathFieldCard extends StatelessWidget {
  const SettingPathFieldCard({
    super.key,
    required this.icon,
    required this.ctrl,
    required this.hint,
    required this.save,
    required this.restoreDefault,
  });

  final IconData icon;
  final TextEditingController ctrl;
  final String hint;
  final void Function(String) save;
  final String Function() restoreDefault;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return SettingCard(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 18, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: ctrl,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: hint,
                    isDense: true,
                    border: InputBorder.none,
                  ),
                  onSubmitted: (v) => save(v),
                ),
              ),
              TextButton(
                onPressed: () {
                  final def = restoreDefault();
                  ctrl.text = def;
                  save(def);
                },
                child: Text(l10n.settingsRestoreDefault),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
