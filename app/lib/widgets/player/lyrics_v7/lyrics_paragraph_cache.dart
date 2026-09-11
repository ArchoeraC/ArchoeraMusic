// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词段落缓存（P1 渲染优化）：消除每帧 `TextPainter.layout()` 与逐行 `saveLayer`。
///
/// - 以「内容 + 样式 + 颜色」为键缓存已排版的 [ui.Paragraph]，键未变即复用，
///   避免重复 shaping（字形选择/定位）；
/// - 只缓存**可见窗口**：painter 每帧调用 [pruneTo] 淘汰不可见行 → 常驻 O(视口)，
///   与歌长无关（见 docs/player-render-optimization.md §3.4）；
/// - 逐字扫亮的活跃行颜色逐帧变化，不缓存（每帧仅此 1 行重建）；
/// - 切歌 / 字号 / 字体 / 宽度变化时由状态层 [clear]。
library;

import 'dart:ui' as ui;

/// 单行缓存槽（主行 + 可选翻译）。
class _LineSlot {
  Object? mainKey;
  ui.Paragraph? main;
  Object? translationKey;
  ui.Paragraph? translation;
}

/// 歌词段落缓存。
class LyricsParagraphCache {
  final Map<int, _LineSlot> _lines = <int, _LineSlot>{};

  /// 取（或构建）第 [index] 行的主段落。[key] 相同则复用，否则调用 [build] 重建。
  ui.Paragraph obtainMain(int index, Object key, ui.Paragraph Function() build) {
    final slot = _lines.putIfAbsent(index, _LineSlot.new);
    if (slot.main != null && slot.mainKey == key) return slot.main!;
    final p = build();
    slot.main = p;
    slot.mainKey = key;
    return p;
  }

  /// 取（或构建）第 [index] 行的翻译段落。
  ///
  /// [key] 为 null 表示当前无翻译：清空该槽并返回 null。
  ui.Paragraph? obtainTranslation(
    int index,
    Object? key,
    ui.Paragraph Function() build,
  ) {
    final slot = _lines.putIfAbsent(index, _LineSlot.new);
    if (slot.translationKey == key) return slot.translation;
    if (key == null) {
      slot.translation = null;
      slot.translationKey = null;
      return null;
    }
    final p = build();
    slot.translation = p;
    slot.translationKey = key;
    return p;
  }

  /// 只保留 [visible] 中的行，淘汰其余（可见窗口缓存，内存有界）。
  void pruneTo(Set<int> visible) {
    if (_lines.isEmpty) return;
    _lines.removeWhere((k, _) => !visible.contains(k));
  }

  /// 清空全部缓存（切歌 / 布局尺寸 / 字体变化）。
  void clear() => _lines.clear();

  /// 当前缓存的行数（测试用）。
  int get entryCount => _lines.length;
}
