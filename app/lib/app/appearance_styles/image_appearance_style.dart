// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io' show File;

import 'package:material_ui/material_ui.dart';

import '../../stores/app_prefs.dart';
import '../../widgets/common/baked_image_background.dart';
import 'appearance_style.dart';

/// 图片背景外观（对齐原版 AppBackground.vue）。
///
/// 未选图时 `effectiveImageBackground` 为 false，界面回退纯色观感；设置页仍按
/// [usesImageBackground] 显示选图入口，便于用户先切换风格再挑图。
class ImageAppearanceStyle extends AppearanceStyle {
  const ImageAppearanceStyle();

  @override
  String get id => 'image';

  @override
  bool get usesImageBackground => true;

  @override
  bool effectiveImageBackground(AppPrefs prefs) =>
      prefs.backgroundImage != null;

  @override
  Widget? buildBackground(BuildContext context, AppPrefs prefs) {
    final path = prefs.backgroundImage;
    if (path == null) return null;
    if (path.isEmpty) return const SizedBox.shrink();
    // 背景铺满全屏又带模糊/遮罩，无需原图全分辨率：按屏幕物理尺寸解码，
    // 大壁纸（4K+）可省数 MB 解码位图内存。
    final screen = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final decodeW = (screen.width * dpr).round().clamp(1, 2560);
    final decodeH = (screen.height * dpr).round().clamp(1, 2560);
    return ClipRect(
      // 一次性烘焙成静态纹理：避免实时 `ImageFiltered` 在每帧重算全屏模糊
      // （Impeller 无图层光栅缓存，见 [BakedImageBackground]）。
      child: BakedImageBackground(
        provider: ResizeImage.resizeIfNeeded(
          decodeW,
          decodeH,
          FileImage(File(path)),
        ),
        blurSigma: prefs.backgroundBlur.toDouble(),
        scale: prefs.backgroundScale,
        dim: prefs.backgroundDim,
      ),
    );
  }
}
