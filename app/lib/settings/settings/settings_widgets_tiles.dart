// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_widgets.dart';

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
    final Widget tile = Padding(
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
    return MouseDodge(child: tile);
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

/// 渲染帧率滑块的颜色阈值：≤60 沿用主题色，>60 黄色，>100 红色。
const int kRenderFpsWarnFrom = 60;
const int kRenderFpsDangerFrom = 100;

/// 帧率告警黄（设计体系没有 warning token，取暗/亮色板都协调的琥珀色）。
const Color kRenderFpsWarnColor = Color(0xFFFFB020);

/// 渲染帧率滑块的前景色：[ColorScheme.primary] / 告警黄 / [ColorScheme.error]。
///
/// 阈值是「超过」：60 仍是主题色，61 起黄色，101 起红色。
Color renderFpsSliderColor(ColorScheme scheme, int fps) {
  if (fps > kRenderFpsDangerFrom) return scheme.error;
  if (fps > kRenderFpsWarnFrom) return kRenderFpsWarnColor;
  return scheme.primary;
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
    this.accentColor,
    this.enabled = true,
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

  /// 自定义滑块前景色（轨道/滑块/数值气泡）；null = 跟随主题主色。
  ///
  /// 用于「数值跨阈值变色」的滑块（如渲染帧率），其余滑块保持统一外观。
  final Color? accentColor;

  /// 是否可拖动；关闭时仍显示当前值（保留用户设置）。
  final bool enabled;
  final ValueChanged<double>? onChangeEnd;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = accentColor;
    Widget slider = Slider(
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      label: label,
      onChangeEnd: enabled ? onChangeEnd : null,
      onChanged: enabled ? onChanged : null,
    );
    if (accent != null) {
      // 与主题默认滑块同构，只换前景色：轨道 / 滑块 / 触摸光晕 / 数值气泡，
      // 气泡文字按前景色亮度自动取黑或白，亮色主题下也保持可读。
      final onAccent = accent.computeLuminance() > 0.5
          ? const Color(0xFF1A1A1A)
          : const Color(0xFFFFFFFF);
      slider = SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: accent,
          thumbColor: accent,
          overlayColor: accent.withValues(alpha: 0.12),
          // 帧率滑块是 1 FPS 一档（135 档）：照常画刻度会在 140px 轨道上
          // 糊成一条实心带，故隐藏刻度点，其余尺寸/形状与其它滑块一致。
          tickMarkShape: SliderTickMarkShape.noTickMark,
          valueIndicatorColor: accent,
          valueIndicatorTextStyle: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: onAccent,
          ),
        ),
        child: slider,
      );
    }
    return SettingTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: SizedBox(width: width, child: slider),
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
