// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:collection';
import 'dart:ui' show Rect;

/// 有界脏区累加器（逻辑坐标）。
///
/// 参照 `docs/runtime-resource-optimization.md` §3.9（Slint `DirtyRegion` 至多 3 个
/// 矩形、按最小增长合并）与 §4.6，用于播放页背景动态层（R1）收集每帧需重绘的区域，
/// 避免整屏重绘。
///
/// 语义：
/// - [add] 忽略空矩形；若已有矩形完全包含新矩形则不动作；丢弃被新矩形完全包含的旧
///   矩形；矩形数未达 [maxRects] 时追加，否则与「并集增长最小」的旧矩形合并。
/// - [intersect] 以裁剪矩形逐项求交并丢弃空结果。
/// - [union] 等价于对另一实例的矩形逐个 [add]。
class DamageRegion {
  DamageRegion({this.maxRects = 3}) : assert(maxRects >= 1, 'maxRects 必须 >= 1');

  final int maxRects;

  final List<Rect> _rects = <Rect>[];

  void add(Rect rect) {
    if (rect.isEmpty) return;
    for (final existing in _rects) {
      if (_contains(existing, rect)) return;
    }
    _rects.removeWhere((existing) => _contains(rect, existing));
    if (_rects.length < maxRects) {
      _rects.add(rect);
      return;
    }
    var bestIndex = 0;
    var bestGrowth = double.infinity;
    for (var i = 0; i < _rects.length; i++) {
      final merged = _rects[i].expandToInclude(rect);
      final growth =
          merged.width * merged.height - _rects[i].width * _rects[i].height;
      if (growth < bestGrowth) {
        bestGrowth = growth;
        bestIndex = i;
      }
    }
    _rects[bestIndex] = _rects[bestIndex].expandToInclude(rect);
  }

  void addAll(Iterable<Rect> rects) {
    for (final rect in rects) {
      add(rect);
    }
  }

  void clear() => _rects.clear();

  bool get isEmpty => _rects.isEmpty;

  bool get isNotEmpty => _rects.isNotEmpty;

  List<Rect> get rects => UnmodifiableListView<Rect>(_rects);

  Rect? get boundingRect {
    if (_rects.isEmpty) return null;
    var result = _rects.first;
    for (var i = 1; i < _rects.length; i++) {
      result = result.expandToInclude(_rects[i]);
    }
    return result;
  }

  bool intersects(Rect rect) {
    for (final existing in _rects) {
      if (existing.overlaps(rect)) return true;
    }
    return false;
  }

  void union(DamageRegion other) => addAll(other.rects);

  void intersect(Rect clip) {
    var write = 0;
    for (final rect in _rects) {
      final clipped = rect.intersect(clip);
      if (!clipped.isEmpty) _rects[write++] = clipped;
    }
    _rects.length = write;
  }

  static bool _contains(Rect outer, Rect inner) =>
      outer.left <= inner.left &&
      outer.top <= inner.top &&
      outer.right >= inner.right &&
      outer.bottom >= inner.bottom;
}
