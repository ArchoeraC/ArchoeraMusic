// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词格式选择（跨平台共享）：把「逐字富格式 vs 标准 LRC」的优先级策略
/// 集中到一处，各平台只负责把自己的候选内容喂进来。
///
/// 背景：netease 的 `yrc`、QQ 的 `qrc`、kugou 的 `krc` 都是逐字富格式，
/// 各平台原先各写一份 `_pickMain` / `_pickFormatted`；本文件统一为
/// [pickLyricFormat]，用户「格式顺序」（[AppPrefs.preferWordByWord]）
/// 只需换算成一个布尔传入。
library;

/// 一个主歌词候选：内容 + 格式标签 + 是否逐字（富格式）。
class LyricFormatCandidate {
  const LyricFormatCandidate({
    required this.content,
    required this.format,
    this.wordByWord = false,
  });

  /// 原始文本（可为 null/空 = 无此格式）。
  final String? content;

  /// 格式标签（'yrc' / 'qrc' / 'krc' / 'lrc'）。
  final String format;

  /// 是否逐字（富）格式。
  final bool wordByWord;
}

/// 从候选里选主歌词：`preferRich=true` 逐字优先，否则标准 LRC 优先；
/// 空的候选视为无。返回裁剪后的内容与格式；全空返回 null。
({String content, String format})? pickLyricFormat(
  List<LyricFormatCandidate> candidates, {
  required bool preferRich,
}) {
  LyricFormatCandidate? firstWord;
  LyricFormatCandidate? firstPlain;
  for (final c in candidates) {
    final text = c.content?.trim();
    if (text == null || text.isEmpty) continue;
    if (c.wordByWord) {
      firstWord ??= c;
    } else {
      firstPlain ??= c;
    }
  }
  final chosen = preferRich
      ? (firstWord ?? firstPlain)
      : (firstPlain ?? firstWord);
  if (chosen == null) return null;
  return (content: chosen.content!.trim(), format: chosen.format);
}

/// 歌词内容缓存的平台键：标准 LRC 优先时用独立命名空间，避免与逐字结果
/// 在同一 (platform, id) 槽位互相污染。
String lyricCachePlatform(String platform, {required bool preferRich}) =>
    preferRich ? platform : '$platform#lrc';
