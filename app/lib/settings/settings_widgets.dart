import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../l10n/l10n.dart';
import '../theme/app_theme.dart';
import '../widgets/common/toast.dart';
import '../widgets/player/s_controls.dart';

/// 设置行：图标徽章 + 标题 + 副标题 + 右侧控件（对齐原项目 SPlayer 设置行）。
class SettingTile extends StatelessWidget {
  const SettingTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;

  /// 禁用时整行变灰（图标/标题/副标题降透明度），配合右侧控件禁用。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = enabled
        ? scheme.primary
        : scheme.primary.withValues(alpha: 0.35);
    final textFg = enabled
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: 0.38);
    final subFg = enabled
        ? scheme.onSurfaceVariant.withValues(alpha: 0.75)
        : scheme.onSurfaceVariant.withValues(alpha: 0.35);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: fg.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 18, color: fg),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: textFg,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: subFg),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    );
  }
}

/// 设置卡片容器（圆角底 + 弱边框，内部纵向排列子项）。
class SettingCard extends StatelessWidget {
  const SettingCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.3)),
      ),
      child: Column(children: children),
    );
  }
}

/// 设置行 + 右侧开关。
class SettingSwitchTile extends StatelessWidget {
  const SettingSwitchTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SettingTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      enabled: enabled,
      trailing: Switch(value: value, onChanged: enabled ? onChanged : null),
    );
  }
}

/// 设置行 + 右侧滑块。
class SettingSliderTile extends StatelessWidget {
  const SettingSliderTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    this.label,
    this.width = 140,
    this.onChangeEnd,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final double width;
  final ValueChanged<double>? onChangeEnd;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return SettingTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: SizedBox(
        width: width,
        child: Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: label,
          onChangeEnd: onChangeEnd,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// 设置分区小标题。
class SettingSectionTitle extends StatelessWidget {
  const SettingSectionTitle({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
        ),
      ),
    );
  }
}

/// 灰色说明文字（设置项下方的灰色 note）。
class SettingNote extends StatelessWidget {
  const SettingNote({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
      ),
    );
  }
}

/// 设置分区：小标题 + 卡片（可选底部灰色说明）。
class SettingSection extends StatelessWidget {
  const SettingSection({
    super.key,
    required this.title,
    required this.children,
    this.note,
  });

  final String title;
  final List<Widget> children;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSectionTitle(title: title),
        SettingCard(children: children),
        if (note != null) ...[
          const SizedBox(height: 8),
          SettingNote(text: note!),
        ],
      ],
    );
  }
}

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
