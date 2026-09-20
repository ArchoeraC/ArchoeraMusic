// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 统一歌词解码：`LyricMatchResult` → 按行对齐的 [LyricGroup]。
///
/// 集中在此，保证所有来源（在线 / 本地 / 流媒体）走同一套解析；无时间
/// 标签的纯文本降级为整段静态展示（本地内嵌歌词常见）。
library;

import '../../../apis/lyric/types.dart';
import '../lyric_line.dart';

List<LyricGroup> decodeLyricGroups(
  LyricMatchResult match, {
  bool plainTextFallback = false,
}) {
  final groups = parseLyricGroups(
    content: match.content,
    format: match.format,
    translation: match.translation,
    romaji: match.romaji,
  );
  if (groups.isNotEmpty) return groups;
  if (!plainTextFallback) return const [];
  return match.content
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .map((l) => LyricGroup(original: LyricLine(timeMs: 0, text: l)))
      .toList();
}
