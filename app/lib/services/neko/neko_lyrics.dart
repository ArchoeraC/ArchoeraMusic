// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 平台的歌词归一化与富歌词预检。
///
/// 覆盖两种服务端载荷：
/// - `data.lyrics` 的**非标准 LRC**（本文件 [parseNekoLyrics]）；
/// - `data.lyricsRich` 的 `neko-v1` JSON（逐字 / 翻译 / 音译；结构解析在
///   通用引擎 `services/lyrics/lyric_line.dart`，本文件只做「是否存在可展示
///   行」的轻量预检，避免歌词来源层为广告兜底而重复构造整首歌词组）。
///
/// ## 非标准 LRC
///
/// 平台音乐详情 `/api/music/info/{id}` 的 `data.lyrics` 返回的歌词形如：
///
///   # 可选注释
///   [00:12.34]歌词正文
///   {"译文"}
///   [00:15.00]下一句
///   {'下一句译文'}
///
/// 即「带时间戳的正文行」紧跟一行**无时间戳**的 `{"译文"}`（大括号内为
/// 带引号的译文，单双引号均可——与后端 `LyricsPlainTextExtractor` 的
/// `TRANSLATION_LINE` 约定一致）。标准 LRC 解析器（[parseLyricGroups]）
/// 会丢弃所有无时间戳行，导致译文全部丢失；部分条目还会把译文写成
/// `[00:12.34]{"译文"}`（带时间戳）。
///
/// 本函数把两种写法都归一化为「标准主歌词 LRC + 独立译文 LRC」，复用引擎
/// 既有的翻译对齐逻辑（[LyricMatchResult.translation]），不侵入通用解析器。
library;

import 'dart:convert';

import '../lyrics/ad_filter.dart';

/// 归一化结果：主歌词（标准 LRC）+ 可选译文（标准 LRC）。
class NekoParsedLyrics {
  const NekoParsedLyrics({required this.content, this.translation});

  /// 标准 LRC 主歌词（时间戳 + 正文）。
  final String content;

  /// 标准 LRC 译文（与主歌词同时间戳）；无译文为 null。
  final String? translation;
}

/// 时间戳标签（与解析器一致）：`[mm:ss]` / `[mm:ss.xx]` / `[mm:ss.xxx]`。
final RegExp _tsRe = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

/// 整行 `{...}`（译文）匹配。
final RegExp _braceRe = RegExp(r'^\{(.*)\}$', dotAll: true);

/// 归一化 Neko 非标准 LRC（见库注释）。
NekoParsedLyrics parseNekoLyrics(String raw) {
  final main = <String>[];
  final trans = <String>[];
  // 最近一条正文行的时间戳标签（供无时间戳的 `{译文}` 归属）。
  var lastTs = <String>[];

  for (final rawLine in raw.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    final timestamps = _tsRe.allMatches(line).map((m) => m.group(0)!).toList();
    // 去掉时间戳后的正文（用于判断是否为整行 `{译文}`）。
    final body = line.replaceAll(_tsRe, '').trim();

    final brace = _braceRe.firstMatch(body);
    if (brace != null) {
      final text = _unquote(brace.group(1)!.trim());
      if (text.isEmpty) continue;
      // 译文行：带时间戳用它自己，否则沿用上一正文行的时间戳。
      final ts = timestamps.isNotEmpty ? timestamps : lastTs;
      for (final t in ts) {
        trans.add('$t$text');
      }
      continue;
    }

    // 无时间戳且非译文的行（LRC 元信息 `[ar:]`/`[ti:]` 等）跳过，
    // 与标准解析器保持一致。
    if (timestamps.isEmpty) continue;

    main.add(line);
    lastTs = timestamps;
  }

  return NekoParsedLyrics(
    content: main.join('\n'),
    translation: trans.isEmpty ? null : trans.join('\n'),
  );
}

/// 去掉译文外层成对引号（`"..."` / `'...'`）；无引号原样返回。
String _unquote(String s) {
  if (s.length >= 2) {
    final first = s[0];
    if ((first == '"' || first == "'") && s.endsWith(first)) {
      return s.substring(1, s.length - 1).trim();
    }
  }
  return s;
}

/// `neko-v1` 富歌词 JSON 是否至少有一行可展示内容（非广告 / 非空）。
///
/// 歌词来源用它决定「富歌词候选是否可用」：整首都是站点广告/占位时丢弃该
/// 候选，交给兼容 LRC 或标准音源回退。只做结构预检，不构造 [LyricGroup]；
/// 真正的解析仍由引擎 `parseNekoV1Lyrics` 完成（单一解析职责）。
bool nekoV1HasDisplayableLine(String richJson) {
  final raw = richJson.trim();
  if (raw.isEmpty) return false;
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return false;
  }
  if (decoded is! Map) return false;
  final lines = decoded['lines'];
  if (lines is! List) return false;
  for (final line in lines) {
    if (line is! Map) continue;
    // 与 parseNekoV1Lyrics 的接受条件保持一致：必须有有效起始时间。
    final start = line['startMs'];
    final startMs = start is num
        ? start.toInt()
        : int.tryParse(start?.toString().trim() ?? '');
    if (startMs == null || startMs < 0) continue;
    final text = line['text']?.toString().trim() ?? '';
    if (text.isNotEmpty && !isAdMetadataText(text)) return true;
  }
  return false;
}
