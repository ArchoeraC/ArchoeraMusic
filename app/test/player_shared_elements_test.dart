// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 共享元素变换的几何回归。
///
/// 布局切换时，封面按 `object-fit: cover` 语义等比缩放 + 裁切：
/// - 变换后的自然矩形必须**覆盖**动画矩形（不能留黑边）；
/// - 变换后的裁切矩形必须**等于**动画矩形（画面不被切掉一部分）。
///
/// 这里直接验证矩阵/裁切数学，防止「切到默认布局时封面只剩四分之一」
/// 这类坐标原点错误回归（旧实现把页面坐标当成边界局部坐标）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/widgets/player/player_shared_elements.dart';

/// 矩阵是「位移 → 缩放」，直接对点做 `origin + scale * p`。
///
/// 注意：`Transform` 的子级坐标原点在共享元素边界的左上角，所以矩阵接收的
/// 是**局部分坐标**；换算回页面坐标要再加 [natural].topLeft。
Offset _map(Matrix4 m, Offset p) => Offset(
  m.storage[12] + m.storage[0] * p.dx,
  m.storage[13] + m.storage[5] * p.dy,
);

Rect _mapLocal(Matrix4 m, Rect r) =>
    Rect.fromPoints(_map(m, r.topLeft), _map(m, r.bottomRight));

Rect _mapPage(Matrix4 m, Rect r, Rect natural) =>
    _mapLocal(m, r).shift(natural.topLeft);

/// 右侧渐隐的整幅封面：不是正方形，也不从页面原点开始。
const Rect _posterRect = Rect.fromLTWH(0, 0, 819.6, 768);
const Rect _squareRect = Rect.fromLTWH(529.5, 172.5, 307, 307);

void main() {
  group('封面：等比缩放 + 裁切', () {
    test('整幅封面 → 方形封面：裁切矩形映射回动画矩形', () {
      const t = PlayerSharedElementTransform(
        natural: _posterRect,
        animated: _squareRect,
      );
      final m = t.matrixFor(PlayerSharedElement.cover);
      // 裁切在局部坐标里裁出可见区域，变换后必须正好是动画矩形。
      final mappedClip = _mapPage(m, t.coverClipRect, _posterRect);
      expect(mappedClip.left, closeTo(_squareRect.left, 0.01));
      expect(mappedClip.top, closeTo(_squareRect.top, 0.01));
      expect(mappedClip.right, closeTo(_squareRect.right, 0.01));
      expect(mappedClip.bottom, closeTo(_squareRect.bottom, 0.01));
      // cover 语义：等比放大后的自然矩形要覆盖动画矩形（无黑边）。
      final mappedNatural = _mapPage(
        m,
        Rect.fromLTWH(0, 0, _posterRect.width, _posterRect.height),
        _posterRect,
      );
      expect(mappedNatural.left, lessThanOrEqualTo(_squareRect.left + 0.01));
      expect(mappedNatural.top, lessThanOrEqualTo(_squareRect.top + 0.01));
      expect(
        mappedNatural.right,
        greaterThanOrEqualTo(_squareRect.right - 0.01),
      );
      expect(
        mappedNatural.bottom,
        greaterThanOrEqualTo(_squareRect.bottom - 0.01),
      );
    });

    test('方形封面 → 整幅封面：裁切不超出自然矩形', () {
      const t = PlayerSharedElementTransform(
        natural: _squareRect,
        animated: _posterRect,
      );
      final m = t.matrixFor(PlayerSharedElement.cover);
      final mappedClip = _mapPage(m, t.coverClipRect, _squareRect);
      expect(mappedClip.left, closeTo(_posterRect.left, 0.01));
      expect(mappedClip.top, closeTo(_posterRect.top, 0.01));
      expect(mappedClip.right, closeTo(_posterRect.right, 0.01));
      expect(mappedClip.bottom, closeTo(_posterRect.bottom, 0.01));
      // 自然矩形左上角不在页面原点：旧实现会把这个偏移重复算一次，
      // 导致裁切跑到画面外、只剩四分之一可见。
      expect(t.coverClipRect.width, lessThanOrEqualTo(_squareRect.width));
      expect(t.coverClipRect.height, lessThanOrEqualTo(_squareRect.height));
      expect(t.coverClipRect.left, greaterThanOrEqualTo(-0.01));
      expect(t.coverClipRect.top, greaterThanOrEqualTo(-0.01));
    });

    test('无过渡：矩阵为单位阵、裁切为自然矩形', () {
      const t = PlayerSharedElementTransform(
        natural: _squareRect,
        animated: _squareRect,
      );
      final m = t.matrixFor(PlayerSharedElement.cover);
      final mappedClip = _mapPage(m, t.coverClipRect, _squareRect);
      expect(mappedClip.left, closeTo(_squareRect.left, 0.01));
      expect(mappedClip.top, closeTo(_squareRect.top, 0.01));
      expect(mappedClip.width, closeTo(_squareRect.width, 0.01));
      expect(mappedClip.height, closeTo(_squareRect.height, 0.01));
    });
  });

  group('信息 / 歌词：矩形非等比缩放', () {
    test('矩阵把自然矩形映射到动画矩形', () {
      const natural = Rect.fromLTWH(683, 58, 187.3, 51);
      const animated = Rect.fromLTWH(590.4, 499.5, 185.2, 54);
      const t = PlayerSharedElementTransform(
        natural: natural,
        animated: animated,
      );
      for (final kind in [
        PlayerSharedElement.info,
        PlayerSharedElement.lyrics,
      ]) {
        final mapped = _mapPage(
          t.matrixFor(kind),
          Rect.fromLTWH(0, 0, natural.width, natural.height),
          natural,
        );
        expect(mapped.left, closeTo(animated.left, 0.01));
        expect(mapped.top, closeTo(animated.top, 0.01));
        expect(mapped.right, closeTo(animated.right, 0.01));
        expect(mapped.bottom, closeTo(animated.bottom, 0.01));
      }
    });

    test('零尺寸自然矩形不产生 NaN', () {
      const t = PlayerSharedElementTransform(
        natural: Rect.fromLTWH(0, 0, 0, 0),
        animated: Rect.fromLTWH(10, 20, 30, 40),
      );
      final m = t.matrixFor(PlayerSharedElement.info);
      for (final v in m.storage) {
        expect(v.isNaN, isFalse);
      }
    });
  });
}
