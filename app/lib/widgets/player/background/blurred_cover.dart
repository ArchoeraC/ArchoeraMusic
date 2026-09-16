// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 模糊封面背景与水纹共用的颜色滤镜。
library;

import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../list/cover_image.dart';

/// 饱和度颜色滤镜（对齐上游 `saturate`），供水纹与模糊背景共用。
ColorFilter saturationColorFilter(double saturation) {
  final s = saturation;
  final inv = 1 - s;
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  return ColorFilter.matrix(<double>[
    inv * lr + s,
    inv * lg,
    inv * lb,
    0,
    0,
    inv * lr,
    inv * lg + s,
    inv * lb,
    0,
    0,
    inv * lr,
    inv * lg,
    inv * lb + s,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]);
}

/// 模糊封面背景（对齐上游 `.bg-blur-wrap`：`blur(45px) saturate(1.2)`
/// + `scale(1.5)` + 50% 压暗）。
class BlurredCover extends StatelessWidget {
  const BlurredCover({super.key, required this.cover});

  final String cover;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 800.0;
        final h = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 800.0;
        return Stack(
          fit: StackFit.expand,
          children: [
            ColorFiltered(
              colorFilter: saturationColorFilter(1.2),
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: 45,
                  sigmaY: 45,
                  tileMode: TileMode.clamp,
                ),
                child: Transform.scale(
                  scale: 1.5,
                  child: CoverImage(
                    cover: cover,
                    width: w,
                    height: h,
                    radius: 0,
                    iconSize: 0,
                  ),
                ),
              ),
            ),
            ColoredBox(color: Colors.black.withValues(alpha: 0.5)),
          ],
        );
      },
    );
  }
}
