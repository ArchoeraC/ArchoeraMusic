/// 基础控件（对齐 SPlayer-Next 的 SButton / SInput 语义，自绘观感，
/// 不依赖 Material 原生按钮外观）。
library;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../common/anim.dart';

/// 按钮样式。
enum SButtonVariant { primary, secondary, ghost, error }

/// 按钮尺寸（高度）。
enum SButtonSize { small, medium, large }

/// 悬浮圆角按钮（自绘：InkWell + AnimatedContainer）。
class SButton extends StatelessWidget {
  const SButton({
    super.key,
    required this.label,
    this.icon,
    this.variant = SButtonVariant.secondary,
    this.size = SButtonSize.medium,
    this.round = false,
    this.circle = false,
    this.loading = false,
    this.block = false,
    this.onPressed,
  });

  final String label;
  final IconData? icon;
  final SButtonVariant variant;
  final SButtonSize size;
  final bool round;
  final bool circle;
  final bool loading;
  final bool block;
  final VoidCallback? onPressed;

  double get _height => switch (size) {
        SButtonSize.small => 28,
        SButtonSize.medium => 36,
        SButtonSize.large => 42,
      };

  double get _fontSize => switch (size) {
        SButtonSize.small => 12.5,
        SButtonSize.medium => 14,
        SButtonSize.large => 15,
      };

  double get _iconSize => switch (size) {
        SButtonSize.small => 15,
        SButtonSize.medium => 18,
        SButtonSize.large => 20,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null && !loading;

    final (Color bg, Color fg, Color hoverBg) = switch (variant) {
      SButtonVariant.primary => (
          scheme.primary,
          scheme.onPrimary,
          scheme.primary.withValues(alpha: 0.85),
        ),
      SButtonVariant.secondary => (
          scheme.surfaceContainerHighest,
          scheme.onSurface,
          scheme.onSurface.withValues(alpha: 0.1),
        ),
      SButtonVariant.ghost => (
          Colors.transparent,
          scheme.onSurfaceVariant,
          scheme.onSurface.withValues(alpha: 0.07),
        ),
      SButtonVariant.error => (
          scheme.error,
          scheme.onError,
          scheme.error.withValues(alpha: 0.85),
        ),
    };

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(circle || round ? AppRadius.pill : AppRadius.control),
            hoverColor: enabled ? hoverBg : Colors.transparent,
            onTap: enabled ? onPressed : null,
            child: AnimatedContainer(
              duration: animDuration(
                  context, const Duration(milliseconds: 150)),
              width: block ? double.infinity : (circle ? _height : null),
              height: _height,
              padding: circle ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: bg.withValues(alpha: enabled ? 1 : 0.45),
                borderRadius:
                    BorderRadius.circular(circle || round ? AppRadius.pill : AppRadius.control),
              ),
              child: Row(
                mainAxisSize: circle || block ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: circle ? MainAxisAlignment.center : MainAxisAlignment.center,
                children: [
                  if (loading) ...[
                    SizedBox(
                      width: _iconSize,
                      height: _iconSize,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: fg.withValues(alpha: 0.85),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ] else if (icon != null) ...[
                    Icon(icon, size: _iconSize, color: fg.withValues(alpha: enabled ? 1 : 0.7)),
                    if (!circle) const SizedBox(width: 6),
                  ],
                  if (!circle)
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fg.withValues(alpha: enabled ? 1 : 0.7),
                          fontSize: _fontSize,
                          fontWeight: variant == SButtonVariant.primary ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 圆角填充式输入框（对齐 SPlayer-Next SInput）。
class SInput extends StatefulWidget {
  const SInput({
    super.key,
    this.controller,
    this.focusNode,
    this.hintText,
    this.prefixIcon,
    this.clearable = false,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction,
    this.width,
    this.autofocus = false,
    this.keyboardType,
    this.enabled = true,
    this.obscureText = false,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hintText;
  final IconData? prefixIcon;
  final bool clearable;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;
  final double? width;
  final bool autofocus;
  final TextInputType? keyboardType;
  final bool enabled;
  final bool obscureText;

  @override
  State<SInput> createState() => _SInputState();
}

class _SInputState extends State<SInput> {
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController();
  late final bool _ownsController = widget.controller == null;

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: widget.width,
      child: TextField(
        controller: _controller,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        enabled: widget.enabled,
        obscureText: widget.obscureText,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        onSubmitted: widget.onSubmitted,
        onChanged: widget.onChanged,
        style: const TextStyle(fontSize: 13.5),
        cursorColor: scheme.primary,
        decoration: InputDecoration(
          hintText: widget.hintText,
          prefixIcon: widget.prefixIcon == null
              ? null
              : Icon(widget.prefixIcon, size: 17, color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
          prefixIconConstraints: const BoxConstraints(minWidth: 36),
          suffixIcon: widget.clearable
              ? ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _controller,
                  builder: (context, value, _) => AnimatedOpacity(
                    duration: animDuration(
                        context, const Duration(milliseconds: 120)),
                    opacity: value.text.isEmpty ? 0 : 1,
                    child: IconButton(
                      tooltip: context.l10n.commonClear,
                      iconSize: 15,
                      onPressed: value.text.isEmpty
                          ? null
                          : () {
                              _controller.clear();
                              widget.onChanged?.call('');
                            },
                      icon: Icon(Icons.close, color: scheme.onSurfaceVariant),
                    ),
                  ),
                )
              : null,
          suffixIconConstraints: const BoxConstraints(minWidth: 32),
        ),
      ),
    );
  }
}

/// 分段控件选项。
class SSegmentedOption<T> {
  const SSegmentedOption(this.value, this.label);

  final T value;
  final String label;
}

/// 自绘分段控件（对齐 SPlayer-Next SRadioGroup 的 pill 分段观感，
/// 替代 Material SegmentedButton）。
///
/// 外观：外层 `onSurface 6%` 圆角 pill，选中项 `primary 12%` 背景 +
/// 主色文字（AnimatedContainer 平滑过渡），每项等宽、悬浮可点击。
class SSegmented<T> extends StatelessWidget {
  const SSegmented({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<SSegmentedOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final o in options) _buildItem(context, scheme, o),
        ],
      ),
    );
  }

  Widget _buildItem(BuildContext context, ColorScheme scheme, SSegmentedOption<T> o) {
    final isSelected = selected == o.value;
    final fg = isSelected ? scheme.primary : scheme.onSurfaceVariant;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(o.value),
        child: AnimatedContainer(
          duration: animDuration(context, const Duration(milliseconds: 150)),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected
                ? scheme.primary.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Text(
            o.label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

