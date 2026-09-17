// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 流体背景的**封面预烘焙**：把专辑封面压到 32×32 → 合并色调 → 盒式模糊，
/// 逐行对齐上游 `MeshGradientRenderer.setAlbum` 的像素处理。
///
/// 上游对 ImageData 依次做：对比度 0.4 → 饱和 3.0 → 对比度 1.7 → 亮度 0.75，
/// 每步都是逐通道仿射且中间值**不夹取**（只在写回 8bit 时夹一次），因此四步可
/// 合并为**单个颜色矩阵**；随后 `blurImage(radius=2, quality=4)` 盒式模糊。
///
/// 全部为纯 CPU 字节运算（32×32×4），每首歌只跑一次，便于单测。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 预烘焙封面边长（对齐上游 `reduceImageSizeCanvas` 的 32×32）。
const int kFluidCoverSize = 32;

/// 盒式模糊半径 / 迭代次数（对齐上游 `blurImage(imageData, 2, 4)`）。
const int kFluidBlurRadius = 2;
const int kFluidBlurQuality = 4;

// 合并颜色矩阵：contrast(0.4) → saturate(3.0) → contrast(1.7) → brightness(0.75)
// 的等价单次仿射 `out = M · in + offset`（推导见文件头；S 为饱和矩阵）。
const double _m00 = 1.224, _m01 = -0.6018, _m02 = -0.1122;
const double _m10 = -0.306, _m11 = 0.9282, _m12 = -0.1122;
const double _m20 = -0.306, _m21 = -0.6018, _m22 = 1.4178;
const double _offset = 30.72;

/// 把任意尺寸的 RGBA8888 封面处理为 `32×32×4` 的 RGBA 字节。
///
/// [src] 为 `ui.Image.toByteData(format: rawStraightRgba)`（或 `rawRgba`，
/// 封面不透明时二者等价）。返回的字节 A 恒为 255。
Uint8List processFluidCover(Uint8List src, int srcW, int srcH) {
  assert(src.length >= srcW * srcH * 4);
  const n = kFluidCoverSize;
  final out = Uint8List(n * n * 4);

  for (var dy = 0; dy < n; dy++) {
    final y0 = (dy * srcH / n).floor();
    var y1 = ((dy + 1) * srcH / n).ceil();
    if (y1 <= y0) y1 = y0 + 1;
    y1 = math.min(y1, srcH);
    for (var dx = 0; dx < n; dx++) {
      final x0 = (dx * srcW / n).floor();
      var x1 = ((dx + 1) * srcW / n).ceil();
      if (x1 <= x0) x1 = x0 + 1;
      x1 = math.min(x1, srcW);

      var sr = 0.0, sg = 0.0, sb = 0.0;
      var count = 0;
      for (var y = y0; y < y1; y++) {
        var p = (y * srcW + x0) * 4;
        for (var x = x0; x < x1; x++) {
          sr += src[p];
          sg += src[p + 1];
          sb += src[p + 2];
          p += 4;
          count++;
        }
      }
      if (count == 0) count = 1;
      final r = sr / count;
      final g = sg / count;
      final b = sb / count;

      final o = (dy * n + dx) * 4;
      out[o] = _clampByte(_m00 * r + _m01 * g + _m02 * b + _offset);
      out[o + 1] = _clampByte(_m10 * r + _m11 * g + _m12 * b + _offset);
      out[o + 2] = _clampByte(_m20 * r + _m21 * g + _m22 * b + _offset);
      out[o + 3] = 255;
    }
  }

  boxBlurRgba(out, n, n, kFluidBlurRadius, kFluidBlurQuality);
  return out;
}

int _clampByte(double v) => v.round().clamp(0, 255);

/// 上游 `blurImage` 的逐位移植（盒式模糊，RGBA 就地处理）。
///
/// 边界按上游做法**钳制到边缘**（重复边缘像素）；`quality` 为重复次数。
void boxBlurRgba(
  Uint8List pixels,
  int width,
  int height,
  int radius,
  int quality,
) {
  final wm = width - 1;
  final hm = height - 1;
  final rad1x = radius + 1;
  final divx = radius + rad1x;
  final rad1y = radius + 1;
  final divy = radius + rad1y;
  final div2 = 1 / (divx * divy);

  final r = Int32List(width * height);
  final g = Int32List(width * height);
  final b = Int32List(width * height);
  final a = Int32List(width * height);
  final vmin = Int32List(math.max(width, height));
  final vmax = Int32List(math.max(width, height));

  var q = quality;
  while (q-- > 0) {
    var yw = 0;
    var yi = 0;
    for (var y = 0; y < height; y++) {
      var rsum = pixels[yw] * rad1x;
      var gsum = pixels[yw + 1] * rad1x;
      var bsum = pixels[yw + 2] * rad1x;
      var asum = pixels[yw + 3] * rad1x;

      for (var i = 1; i <= radius; i++) {
        var p = yw + ((i > wm ? wm : i) << 2);
        rsum += pixels[p++];
        gsum += pixels[p++];
        bsum += pixels[p++];
        asum += pixels[p];
      }

      for (var x = 0; x < width; x++) {
        r[yi] = rsum;
        g[yi] = gsum;
        b[yi] = bsum;
        a[yi] = asum;

        if (y == 0) {
          vmin[x] = math.min(x + rad1x, wm) << 2;
          vmax[x] = math.max(x - radius, 0) << 2;
        }

        var p1 = yw + vmin[x];
        var p2 = yw + vmax[x];
        rsum += pixels[p1++] - pixels[p2++];
        gsum += pixels[p1++] - pixels[p2++];
        bsum += pixels[p1++] - pixels[p2++];
        asum += pixels[p1] - pixels[p2];

        yi++;
      }
      yw += width << 2;
    }

    for (var x = 0; x < width; x++) {
      var yp = x;
      var rsum = r[yp] * rad1y;
      var gsum = g[yp] * rad1y;
      var bsum = b[yp] * rad1y;
      var asum = a[yp] * rad1y;

      for (var i = 1; i <= radius; i++) {
        yp += i > hm ? 0 : width;
        rsum += r[yp];
        gsum += g[yp];
        bsum += b[yp];
        asum += a[yp];
      }

      var yo = x << 2;
      for (var y = 0; y < height; y++) {
        pixels[yo] = (rsum * div2 + 0.5).floor();
        pixels[yo + 1] = (gsum * div2 + 0.5).floor();
        pixels[yo + 2] = (bsum * div2 + 0.5).floor();
        pixels[yo + 3] = (asum * div2 + 0.5).floor();

        if (x == 0) {
          vmin[y] = math.min(y + rad1y, hm) * width;
          vmax[y] = math.max(y - radius, 0) * width;
        }

        final p1 = x + vmin[y];
        final p2 = x + vmax[y];
        rsum += r[p1] - r[p2];
        gsum += g[p1] - g[p2];
        bsum += b[p1] - b[p2];
        asum += a[p1] - a[p2];

        yo += width << 2;
      }
    }
  }
}

/// 把处理后的字节解码为不可变 [ui.Image]（不透明，避免预乘语义歧义）。
Future<ui.Image> decodeFluidCover(Uint8List rgba) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    kFluidCoverSize,
    kFluidCoverSize,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}
