// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

/// 单行文本输入弹窗（设置页共用：WiFi 密码 / 自定义缩放）。
///
/// 关键在于**弹窗自己持有** [TextEditingController] 并在 dispose 中释放：
/// 调用方在 `await show()` 返回后立刻 dispose，会在弹窗**退场动画**进行期间
/// 触发「A TextEditingController was used after being disposed」。
class SettingPromptDialog extends StatefulWidget {
  const SettingPromptDialog({
    super.key,
    required this.title,
    this.description,
    this.initial,
    this.hint,
    this.obscure = false,
    this.suffixText,
    this.confirmLabel,
    this.keyboardType,
  });

  final String title;
  final String? description;
  final String? initial;
  final String? hint;
  final bool obscure;
  final String? suffixText;
  final String? confirmLabel;
  final TextInputType? keyboardType;

  /// 弹出输入框；返回输入文本（取消/关闭返回 null）。
  static Future<String?> show(
    BuildContext context, {
    required String title,
    String? description,
    String? initial,
    String? hint,
    bool obscure = false,
    String? suffixText,
    String? confirmLabel,
    TextInputType? keyboardType,
  }) {
    return showDialog<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      // 与 SDialog.show 同理：挂当前分支 Navigator，避免 pop 掉页面路由。
      useRootNavigator: false,
      builder: (_) => SettingPromptDialog(
        title: title,
        description: description,
        initial: initial,
        hint: hint,
        obscure: obscure,
        suffixText: suffixText,
        confirmLabel: confirmLabel,
        keyboardType: keyboardType,
      ),
    );
  }

  @override
  State<SettingPromptDialog> createState() => _SettingPromptDialogState();
}

class _SettingPromptDialogState extends State<SettingPromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SDialog(
      title: widget.title,
      description: widget.description,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel ?? l10n.commonConfirm),
        ),
      ],
      child: TextField(
        controller: _controller,
        autofocus: true,
        obscureText: widget.obscure,
        keyboardType: widget.keyboardType,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          hintText: widget.hint,
          suffixText: widget.suffixText,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
