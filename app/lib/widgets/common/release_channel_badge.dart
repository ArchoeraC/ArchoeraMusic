// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

import '../../utils/app_version.dart';

/// 发布通道徽标（Release / Beta / Dev / Nightly）。
///
/// 只显示通道名，不显示编译期的 0–3 数字。视觉与设置卡片同一体系：
/// 通道色只作为**低透明度叠层**（底色 10–16% / 描边 30–38%），文字取
/// 与当前明暗主题相称的色阶——不再用高饱和实心块 + 白字 + 白描边，
/// 避免在深色卡片上像贴纸一样突兀，同时仍能区分四个通道。
///
/// 底色不写死：叠在 [ColorScheme] 派生的卡片表面上，因此主题色（含
/// 「跟随封面」）变化时徽标会自动融入，不会与全局配色打架。
class ReleaseChannelBadge extends StatelessWidget {
  const ReleaseChannelBadge({super.key, this.channel});

  /// 通道；默认取编译期 [ReleaseChannel.current]。
  final ReleaseChannel? channel;

  /// 通道色相（仅作叠层与文字的基色，不再直接实心填充）。
  static Color colorOf(ReleaseChannel channel) => switch (channel) {
    ReleaseChannel.release => const Color(0xFF2E7D32),
    ReleaseChannel.beta => const Color(0xFFEF6C00),
    ReleaseChannel.dev => const Color(0xFF1565C0),
    ReleaseChannel.nightly => const Color(0xFF6A1B9A),
  };

  @override
  Widget build(BuildContext context) {
    final c = channel ?? ReleaseChannel.current;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final base = colorOf(c);
    // 深色：文字提亮（叠白 55%）、底色更透；浅色：文字压暗（叠黑 35%）。
    final foreground = dark
        ? Color.lerp(base, Colors.white, 0.55)!
        : Color.lerp(base, Colors.black, 0.35)!;
    return Semantics(
      label: '${c.label} channel',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: base.withValues(alpha: dark ? 0.16 : 0.10),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: base.withValues(alpha: dark ? 0.38 : 0.30)),
        ),
        child: Text(
          c.label,
          style: TextStyle(
            color: foreground,
            fontSize: 10,
            height: 1.1,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}
