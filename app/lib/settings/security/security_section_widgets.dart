// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../security_section.dart';

class _WordConfirmField extends StatefulWidget {
  const _WordConfirmField({
    required this.word,
    required this.hint,
    required this.cancelLabel,
    required this.confirmLabel,
  });

  final String word;
  final String hint;
  final String cancelLabel;
  final String confirmLabel;

  @override
  State<_WordConfirmField> createState() => _WordConfirmFieldState();
}

class _WordConfirmFieldState extends State<_WordConfirmField> {
  final TextEditingController _ctrl = TextEditingController();
  bool _matched = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _ctrl,
          autofocus: true,
          onChanged: (v) => setState(() => _matched = v == widget.word),
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: widget.hint,
            isDense: true,
            errorText: _matched ? null : ' ',
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: scheme.error),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: scheme.outlineVariant),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            SButton(
              label: widget.cancelLabel,
              variant: SButtonVariant.secondary,
              size: SButtonSize.small,
              onPressed: () => Navigator.of(context).pop(false),
            ),
            const SizedBox(width: 10),
            SButton(
              label: widget.confirmLabel,
              variant: SButtonVariant.error,
              size: SButtonSize.small,
              onPressed: _matched
                  ? () => Navigator.of(context).pop(true)
                  : null,
            ),
          ],
        ),
      ],
    );
  }
}

class _RecoveryPasswordField extends StatefulWidget {
  const _RecoveryPasswordField({
    required this.hint,
    required this.optional,
    required this.skipLabel,
    required this.confirmLabel,
  });

  final String hint;
  final bool optional;
  final String skipLabel;
  final String confirmLabel;

  @override
  State<_RecoveryPasswordField> createState() => _RecoveryPasswordFieldState();
}

class _RecoveryPasswordFieldState extends State<_RecoveryPasswordField> {
  final TextEditingController _ctrl = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _confirm() {
    Navigator.of(context).pop(_ctrl.text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: SInput(
                controller: _ctrl,
                autofocus: true,
                obscureText: _obscure,
                hintText: widget.hint,
                prefixIcon: EtaIcons.keyOutline,
                clearable: true,
                textInputAction: TextInputAction.done,
                onSubmitted: widget.optional
                    ? (_) => _confirm()
                    : (_) {
                        if (_ctrl.text.isNotEmpty) _confirm();
                      },
              ),
            ),
            IconButton(
              tooltip: l10n.settingsDeviceBindShowPassword,
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(
                _obscure
                    ? EtaIcons.eyeCloseOutline
                    : EtaIcons.eyeOutline,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            SButton(
              label: l10n.commonCancel,
              variant: SButtonVariant.secondary,
              size: SButtonSize.small,
              onPressed: () => Navigator.of(context).pop(),
            ),
            if (widget.optional) ...[
              const SizedBox(width: 10),
              SButton(
                label: widget.skipLabel,
                variant: SButtonVariant.ghost,
                size: SButtonSize.small,
                onPressed: () => Navigator.of(context).pop(''),
              ),
            ],
            const SizedBox(width: 10),
            SButton(
              label: widget.confirmLabel,
              icon: EtaIcons.check,
              variant: SButtonVariant.primary,
              size: SButtonSize.small,
              onPressed: widget.optional
                  ? _confirm
                  : (_ctrl.text.isNotEmpty ? _confirm : null),
            ),
          ],
        ),
      ],
    );
  }
}

/// 新口令输入（口令 + 二次确认）：两次一致且非空时才允许确认；
/// 不一致或为空时确认按钮禁用并显示错误提示。返回口令字符串 / null（取消）。
class _NewPasswordField extends StatefulWidget {
  const _NewPasswordField({
    required this.hint,
    required this.confirmHint,
    required this.mismatch,
    required this.cancelLabel,
    required this.confirmLabel,
  });

  final String hint;
  final String confirmHint;
  final String mismatch;
  final String cancelLabel;
  final String confirmLabel;

  @override
  State<_NewPasswordField> createState() => _NewPasswordFieldState();
}

class _NewPasswordFieldState extends State<_NewPasswordField> {
  final TextEditingController _ctrl = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _valid =>
      _ctrl.text.isNotEmpty && _ctrl.text == _confirm.text;

  void _submit() {
    if (!_valid) return;
    Navigator.of(context).pop(_ctrl.text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mismatch = _confirm.text.isNotEmpty && _ctrl.text != _confirm.text;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SInput(
          controller: _ctrl,
          autofocus: true,
          obscureText: true,
          hintText: widget.hint,
          prefixIcon: EtaIcons.keyOutline,
          textInputAction: TextInputAction.next,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
        SInput(
          controller: _confirm,
          obscureText: true,
          hintText: widget.confirmHint,
          prefixIcon: EtaIcons.keyOutline,
          textInputAction: TextInputAction.done,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
        ),
        if (mismatch)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              widget.mismatch,
              style: TextStyle(fontSize: 11.5, color: scheme.error),
            ),
          ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            SButton(
              label: widget.cancelLabel,
              variant: SButtonVariant.secondary,
              size: SButtonSize.small,
              onPressed: () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 10),
            SButton(
              label: widget.confirmLabel,
              icon: EtaIcons.check,
              variant: SButtonVariant.primary,
              size: SButtonSize.small,
              onPressed: _valid ? _submit : null,
            ),
          ],
        ),
      ],
    );
  }
}

class _SchemeCard extends StatelessWidget {
  const _SchemeCard({
    required this.value,
    required this.selected,
    this.selectedOverride,
    required this.busy,
    required this.title,
    required this.badge,
    required this.badgeColor,
    required this.desc,
    required this.icon,
    required this.onTap,
  });

  final String value;
  final String selected;

  /// 覆盖选中态（用于「一组多档」的合并卡：组内任一档都算选中）；null = 按 [value] 比对。
  final bool? selectedOverride;
  final bool busy;
  final String title;
  final String badge;
  final Color badgeColor;
  final String desc;
  final IconData icon;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected = selectedOverride ?? (value == selected);
    final fg = isSelected ? badgeColor : scheme.onSurface;
    return MouseRegion(
      cursor: busy ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: busy ? null : () => onTap(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isSelected
                ? badgeColor.withValues(alpha: 0.08)
                : scheme.onSurface.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? badgeColor.withValues(alpha: 0.8)
                  : scheme.outlineVariant.withValues(alpha: 0.5),
              width: isSelected ? 1.6 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18, color: fg),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: fg,
                      ),
                    ),
                  ),
                  if (isSelected)
                    Icon(EtaIcons.checkCircle, size: 16, color: badgeColor),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                desc,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.35,
                  color: busy
                      ? scheme.onSurfaceVariant.withValues(alpha: 0.35)
                      : scheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    fontSize: 9.5,
                    color: badgeColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
