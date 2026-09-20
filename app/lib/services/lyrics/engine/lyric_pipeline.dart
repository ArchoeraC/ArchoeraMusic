// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词后处理管线：解码后的 [LyricGroup] 依次经过各 [LyricPostProcessor]。
///
/// 现有处理器：排除规则、脏话还原（原散落在 `lyrics_provider` 的逻辑）。
/// 顺序固定为「先按原文匹配排除 → 再还原脏话」，与既有行为一致。
library;

import '../lyric_line.dart';
import '../profanity.dart';

/// 单次后处理的输入开关（来自用户偏好）。
class LyricProcessContext {
  const LyricProcessContext({
    this.excludeEnabled = false,
    this.excludeKeywords = const [],
    this.excludeRegexes = const [],
    this.uncensor = false,
  });

  final bool excludeEnabled;
  final List<String> excludeKeywords;
  final List<String> excludeRegexes;
  final bool uncensor;
}

/// 歌词后处理器。
abstract interface class LyricPostProcessor {
  List<LyricGroup> process(List<LyricGroup> groups, LyricProcessContext ctx);
}

/// 按关键词/正则丢弃匹配的歌词行。
///
/// 关键词不区分大小写；正则非法忽略（视为未命中）。
class ExcludeLyricProcessor implements LyricPostProcessor {
  const ExcludeLyricProcessor();

  @override
  List<LyricGroup> process(List<LyricGroup> groups, LyricProcessContext ctx) {
    if (!ctx.excludeEnabled) return groups;
    if (ctx.excludeKeywords.isEmpty && ctx.excludeRegexes.isEmpty) return groups;

    final lowered = [for (final k in ctx.excludeKeywords) k.toLowerCase()];
    final regs = <RegExp>[];
    for (final r in ctx.excludeRegexes) {
      try {
        regs.add(RegExp(r, caseSensitive: false));
      } catch (_) {
        // 非法正则忽略
      }
    }
    bool excluded(String text) {
      final t = text.toLowerCase();
      for (final k in lowered) {
        if (t.contains(k)) return true;
      }
      for (final re in regs) {
        if (re.hasMatch(text)) return true;
      }
      return false;
    }

    return [
      for (final g in groups)
        if (!excluded(g.original.text)) g,
    ];
  }
}

/// 还原被星号遮盖的脏话（原文 / 翻译 / 逐字片段）。
class UncensorLyricProcessor implements LyricPostProcessor {
  const UncensorLyricProcessor();

  @override
  List<LyricGroup> process(List<LyricGroup> groups, LyricProcessContext ctx) {
    if (!ctx.uncensor) return groups;
    return [
      for (final g in groups)
        LyricGroup(
          original: LyricLine(
            timeMs: g.original.timeMs,
            text: unmaskProfanity(g.original.text),
          ),
          translation: g.translation == null
              ? null
              : unmaskProfanity(g.translation!),
          romaji: g.romaji,
          fragments: g.fragments == null
              ? null
              : [
                  for (final f in g.fragments!)
                    LyricFragment(
                      text: unmaskProfanity(f.text),
                      startMs: f.startMs,
                      durationMs: f.durationMs,
                    ),
                ],
          // 必须保留行结束时间：AMLL 引擎用 endMs 判定严格覆盖范围。
          endMs: g.endMs,
          // 背景人声标记：渲染字号/位置与主行不同，重建时必须保留。
          isBG: g.isBG,
        ),
    ];
  }
}

/// 后处理管线：按顺序应用处理器。
class LyricPipeline {
  const LyricPipeline(this.processors);

  final List<LyricPostProcessor> processors;

  /// 标准管线（排除 → 脏话还原）。
  static const LyricPipeline standard = LyricPipeline([
    ExcludeLyricProcessor(),
    UncensorLyricProcessor(),
  ]);

  List<LyricGroup> process(List<LyricGroup> groups, LyricProcessContext ctx) {
    var out = groups;
    for (final p in processors) {
      out = p.process(out, ctx);
    }
    return out;
  }
}
