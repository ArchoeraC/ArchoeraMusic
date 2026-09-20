// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 为 Neko 曲目取**标准 LRC**歌词（下载元数据「强制重写」用）。
///
/// 背景：Neko 是第三方直传音源，其内嵌/平台歌词常为站点广告或非标准
/// 格式（见 `parseNekoLyrics`），不可信。下载写标签时需改用标准音源歌词。
///
/// 顺序：网易（天然标准 LRC）→ QQ → 酷狗；富文本（yrc/qrc/krc）先经
/// 统一解码器解析，再**重新序列化为标准 LRC**（标签只接受纯文本 LRC）。
/// 全部失败返回 null（Rust 侧再走 LRCLIB 兜底）。
library;

import '../../apis/lyric/kugou.dart' show kgGetLyricByQuery;
import '../../apis/lyric/netease.dart' show nmGetLrcByQuery;
import '../../apis/lyric/qqmusic.dart' show qmGetLyricByQuery;
import '../../apis/lyric/types.dart';
import '../lyrics/lyric_line.dart';
import '../netease/track.dart';

/// 按曲目元数据搜索并返回标准 LRC 文本；无命中返回 null。
Future<String?> fetchStandardNekoLyrics(Track track) async {
  // 1) 网易：直接取标准 LRC 字段（无需格式转换）。
  try {
    final lrc = await nmGetLrcByQuery(track);
    if (lrc != null && lrc.trim().isNotEmpty) return lrc;
  } catch (_) {
    // 继续下一源
  }

  // 2) QQ / 酷狗：优先标准 LRC；富文本解码后序列化回标准 LRC。
  final fetchers = <Future<LyricMatchResult?> Function(Track)>[
    (t) => qmGetLyricByQuery(t, preferRich: false),
    (t) => kgGetLyricByQuery(t, preferRich: false),
  ];
  for (final fetch in fetchers) {
    try {
      final match = await fetch(track);
      final lrc = _toStandardLrc(match);
      if (lrc != null && lrc.trim().isNotEmpty) return lrc;
    } catch (_) {
      // 继续下一源
    }
  }
  return null;
}

/// `LyricMatchResult` → 标准 LRC（已是 lrc 直接返回；富文本解码后重建）。
String? _toStandardLrc(LyricMatchResult? match) {
  if (match == null) return null;
  final content = match.content;
  if (content.trim().isEmpty) return null;
  if (match.format == 'lrc') return content;

  final groups = parseLyricGroups(
    content: content,
    format: match.format,
    translation: match.translation,
    romaji: match.romaji,
  );
  if (groups.isEmpty) return null;

  final sb = StringBuffer();
  for (final g in groups) {
    final tag = _lrcTag(g.original.timeMs);
    sb.writeln('$tag${g.original.text}');
    final trans = g.translation;
    if (trans != null && trans.isNotEmpty) sb.writeln('$tag$trans');
  }
  return sb.toString();
}

/// 毫秒 → `[mm:ss.xx]`（LRC 时间标签，两位百分秒）。
String _lrcTag(int ms) {
  final safe = ms < 0 ? 0 : ms;
  final m = safe ~/ 60000;
  final s = (safe % 60000) ~/ 1000;
  final cs = (safe % 1000) ~/ 10;
  return '[${m.toString().padLeft(2, '0')}:'
      '${s.toString().padLeft(2, '0')}.'
      '${cs.toString().padLeft(2, '0')}]';
}
