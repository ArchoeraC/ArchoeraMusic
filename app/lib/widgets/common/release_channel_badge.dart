// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

import '../../utils/app_version.dart';

/// 发布通道徽标（Release / Beta / Dev / Nightly）。
///
/// 只显示通道名，不显示编译期的 0–3 数字。颜色固定为深色系实心底 + 白字，
/// 不随主题或图片背景变化：图片外观（壁纸 + 模糊/压暗）下也能保持对比度；
/// 另加细白边与轻投影，避免落在亮色图片区域时糊成一片。
class ReleaseChannelBadge extends StatelessWidget {
  const ReleaseChannelBadge({super.key, this.channel});

  /// 通道；默认取编译期 [ReleaseChannel.current]。
  final ReleaseChannel? channel;

  /// 通道主色（深色实心，保证白字对比度）。
  static Color colorOf(ReleaseChannel channel) => switch (channel) {
    ReleaseChannel.release => const Color(0xFF1B5E20),
    ReleaseChannel.beta => const Color(0xFFE65100),
    ReleaseChannel.dev => const Color(0xFF0D47A1),
    ReleaseChannel.nightly => const Color(0xFF4A148C),
  };

  @override
  Widget build(BuildContext context) {
    final c = channel ?? ReleaseChannel.current;
    final color = colorOf(c);
    return Semantics(
      label: '${c.label} channel',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Text(
          c.label,
          style: const TextStyle(
            color: Colors.white,
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
