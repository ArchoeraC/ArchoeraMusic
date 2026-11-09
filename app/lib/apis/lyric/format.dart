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

/// 跨平台歌词格式注册表（用户可在「歌词格式顺序」里排序）。
///
/// 只收录**多个平台通用**的格式标识；平台扩展的逐字富格式（如 NekoMusic
/// 的 [kNekoV1LyricsFormat]）不单独暴露给用户排序，而是通过
/// [pickLyricFormat] 的 `wordByWord` 类别跟随「逐字优先 / 标准 LRC 优先」。
const List<String> lyricFormatIds = ['yrc', 'qrc', 'krc', 'lrc'];

/// NekoMusic 富歌词格式标识（平台扩展逐字格式，`neko-v1` JSON）。
const String kNekoV1LyricsFormat = 'neko-v1';

/// 格式是否为逐字（富）格式（含平台扩展格式）。
bool isRichLyricFormat(String format) => switch (format.trim().toLowerCase()) {
  'yrc' || 'qrc' || 'krc' || kNekoV1LyricsFormat => true,
  _ => false,
};

/// 一个主歌词候选：内容 + 格式标签 + 是否逐字（富格式）。
class LyricFormatCandidate {
  const LyricFormatCandidate({
    required this.content,
    required this.format,
    this.wordByWord = false,
  });

  /// 原始文本（可为 null/空 = 无此格式）。
  final String? content;

  /// 格式标签（`yrc` / `qrc` / `krc` / `lrc`，或平台扩展如 `neko-v1`）。
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
    if (c.wordByWord || isRichLyricFormat(c.format)) {
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
