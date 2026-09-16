// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 脏区累加器回归测试：包含消解、上限合并、并交运算与包围盒。
library;

import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/render/damage_region.dart';

void main() {
  test('add 保留不相交矩形与插入顺序', () {
    final region = DamageRegion();
    region.add(const Rect.fromLTWH(0, 0, 10, 10));
    region.add(const Rect.fromLTWH(20, 0, 10, 10));
    expect(region.rects, [
      const Rect.fromLTWH(0, 0, 10, 10),
      const Rect.fromLTWH(20, 0, 10, 10),
    ]);
    expect(region.isEmpty, isFalse);
    expect(region.isNotEmpty, isTrue);
  });

  test('add 忽略空矩形', () {
    final region = DamageRegion();
    region.add(const Rect.fromLTWH(0, 0, 0, 5));
    region.add(const Rect.fromLTWH(3, 3, 4, 0));
    expect(region.isEmpty, isTrue);
    expect(region.rects, isEmpty);
  });

  test('add 对已包含的新矩形不动作', () {
    final region = DamageRegion();
    region.add(const Rect.fromLTWH(0, 0, 10, 10));
    region.add(const Rect.fromLTWH(2, 2, 3, 3));
    expect(region.rects, [const Rect.fromLTWH(0, 0, 10, 10)]);
  });

  test('add 丢弃被新矩形完全包含的旧矩形', () {
    final region = DamageRegion();
    region.add(const Rect.fromLTWH(2, 2, 3, 3));
    region.add(const Rect.fromLTWH(0, 0, 20, 20));
    expect(region.rects, [const Rect.fromLTWH(0, 0, 20, 20)]);
  });

  test('add 达到上限时按最小增长合并', () {
    final region = DamageRegion(maxRects: 3);
    region.add(const Rect.fromLTWH(0, 0, 1, 1));
    region.add(const Rect.fromLTWH(10, 0, 1, 1));
    region.add(const Rect.fromLTWH(20, 0, 1, 1));
    region.add(const Rect.fromLTWH(20, 2, 1, 1));
    expect(region.rects.length, 3);
    expect(region.rects, [
      const Rect.fromLTWH(0, 0, 1, 1),
      const Rect.fromLTWH(10, 0, 1, 1),
      const Rect.fromLTRB(20, 0, 21, 3),
    ]);
  });

  test('intersects 命中与未命中', () {
    final region = DamageRegion();
    region.add(const Rect.fromLTWH(0, 0, 10, 10));
    expect(region.intersects(const Rect.fromLTWH(5, 5, 10, 10)), isTrue);
    expect(region.intersects(const Rect.fromLTWH(20, 20, 5, 5)), isFalse);
  });

  test('union 并入另一实例的全部矩形', () {
    final a = DamageRegion()..add(const Rect.fromLTWH(0, 0, 10, 10));
    final b = DamageRegion()
      ..add(const Rect.fromLTWH(20, 20, 5, 5))
      ..add(const Rect.fromLTWH(30, 30, 5, 5));
    a.union(b);
    expect(a.rects, [
      const Rect.fromLTWH(0, 0, 10, 10),
      const Rect.fromLTWH(20, 20, 5, 5),
      const Rect.fromLTWH(30, 30, 5, 5),
    ]);
  });

  test('intersect 裁剪并丢弃空结果', () {
    final region = DamageRegion();
    region.add(const Rect.fromLTWH(0, 0, 10, 10));
    region.add(const Rect.fromLTWH(20, 20, 5, 5));
    region.intersect(const Rect.fromLTWH(0, 0, 5, 5));
    expect(region.rects, [const Rect.fromLTWH(0, 0, 5, 5)]);
  });

  test('boundingRect 空时为 null，否则为最小包围盒', () {
    final region = DamageRegion();
    expect(region.boundingRect, isNull);
    region.add(const Rect.fromLTWH(0, 0, 10, 10));
    region.add(const Rect.fromLTWH(20, 30, 5, 5));
    expect(region.boundingRect, const Rect.fromLTWH(0, 0, 25, 35));
  });

  test('clear 清空全部状态', () {
    final region = DamageRegion()..add(const Rect.fromLTWH(0, 0, 10, 10));
    region.clear();
    expect(region.isEmpty, isTrue);
    expect(region.boundingRect, isNull);
  });

  test('rects 为不可修改视图', () {
    final region = DamageRegion()..add(const Rect.fromLTWH(0, 0, 10, 10));
    expect(
      () => region.rects.add(const Rect.fromLTWH(0, 0, 1, 1)),
      throwsUnsupportedError,
    );
  });

  test('maxRects 必须 >= 1', () {
    expect(() => DamageRegion(maxRects: 0), throwsA(isA<AssertionError>()));
  });
}
