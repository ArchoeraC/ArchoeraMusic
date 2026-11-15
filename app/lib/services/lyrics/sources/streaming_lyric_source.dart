// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 流媒体歌词来源：向曲目所属服务器直取（Subsonic / Jellyfin / Songloft）。
///
/// - 服务器返回歌词（内嵌扫描）→ 直接用；
/// - 服务端**自带**逐字（`lxlyric`）或罗马音（`rlyric`）时按其格式交给引擎，
///   只在 `preferRich` 时优先逐字；**客户端不主动在线抓取**逐字 / 罗马音；
/// - 服务器为 ArchoeraMusic 且曲库无内嵌歌词时，返回扩展标记
///   [StreamingLyrics.fetchOnline]，此时由**客户端**（本机）自行在线补全：
///   按用户来源顺序查询 netease/qqmusic/kugou。该扩展仅我方服务端 + 我方
///   客户端之间生效，标准 Subsonic 客户端不受影响。
/// - 其它情况返回 null（走播放页空态）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../apis/lyric/format.dart';
import '../../../apis/lyric/kugou.dart';
import '../../../apis/lyric/netease.dart';
import '../../../apis/lyric/qqmusic.dart';
import '../../../apis/lyric/types.dart';
import '../../netease/track.dart';
import '../../streaming/streaming_client.dart';
import '../../streaming/streaming_provider.dart';
import '../../../stores/app_prefs.dart';
import '../engine/lyric_source.dart';

class StreamingLyricSource implements LyricSource {
  StreamingLyricSource(this._ref);

  final Ref _ref;

  @override
  String get id => 'streaming';

  @override
  bool get online => false;

  @override
  bool get plainTextFallback => false;

  @override
  Future<LyricMatchResult?> fetch(LyricRequest request) async {
    final track = request.track;
    final serverId = track.serverId;
    final originalId = track.originalId;
    if (serverId == null || originalId == null || originalId.isEmpty) {
      return null;
    }
    // 凭据按需从 vault 惰性解密后临时构造客户端。
    final cfg =
        await _ref.read(streamingProvider.notifier).resolvedServer(serverId);
    if (cfg == null) return null;
    try {
      final lyrics = await StreamingClient(cfg).getLyrics(
        originalId,
        artist: track.artistNames,
        title: track.title,
      );
      if (lyrics.hasAny) {
        final rich = normalizeStreamingWordLyric(
          lyrics.wordByWord,
          lyrics.wordFormat,
        );
        final translation = _normalizeSubLyric(
          lyrics.translation,
          lyrics.translationFormat,
        );
        final romaji = _normalizeSubLyric(
          lyrics.romaji,
          lyrics.romajiFormat,
        );
        final picked = pickLyricFormat(
          [
            LyricFormatCandidate(
              content: rich?.content,
              format: rich?.format ?? 'lrc',
              wordByWord: true,
            ),
            LyricFormatCandidate(content: lyrics.lrc, format: 'lrc'),
          ],
          preferRich: request.preferRich,
        );
        if (picked != null) {
          // 翻译 / 罗马音只取服务端返回值；服务端没给就不展示。
          return LyricMatchResult(
            platform: 'streaming',
            format: picked.format,
            content: picked.content,
            translation: translation.content,
            translationFormat: translation.format,
            romaji: romaji.content,
            romajiFormat: romaji.format,
          );
        }
      }
      // 仅我方服务端会给出该标记：客户端自行在线补全。
      if (lyrics.fetchOnline && cfg.isArchoeraServer) {
        return await _onlineFallback(track, preferRich: request.preferRich);
      }
    } catch (_) {
      // 无歌词 / 网络失败 → 空态
    }
    return null;
  }

  /// 按用户来源顺序在本机查询在线歌词（服务端无内嵌时的客户端补全）。
  Future<LyricMatchResult?> _onlineFallback(
    Track track, {
    required bool preferRich,
  }) async {
    final prefs = _ref.read(appPrefsProvider);
    for (final platform in prefs.lyricSourceOrder) {
      LyricMatchResult? match;
      try {
        match = switch (platform) {
          'netease' => await nmGetLyricByQuery(track, preferRich: preferRich),
          'qqmusic' => await qmGetLyricByQuery(track, preferRich: preferRich),
          'kugou' => await kgGetLyricByQuery(track, preferRich: preferRich),
          _ => null,
        };
      } catch (_) {
        match = null;
      }
      if (match != null) return match;
    }
    return null;
  }
}

/// 服务端逐字歌词 → 引擎可解析的文本（只做格式归一化，不改语义）。
///
/// 服务端（尤其 Songloft 的歌词插件）可能返回多种逐字形态：
/// - 传统 YRC / KRC / ESLRC（`[mm:ss.xxx]<rel,dur>字`、`<mm:ss.xxx>字`）：原样；
/// - 新版 YRC（`[ms,dur](start,dur,flag)字`）：用 [convertNeteaseNewYrc] 转成
///   传统 YRC；
/// - QRC（`[ms,dur]字(start,dur)`）：原样，引擎会按 `qrc` 自行归一化；
/// - 非标准 `[ms,dur]<rel,dur>字`：仅把行头改写成 `[mm:ss.xxx]`。
///
/// 返回 null 表示没有可用的逐字内容。
({String content, String format})? normalizeStreamingWordLyric(
  String? raw,
  String format,
) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return null;
  if (format == 'qrc') return (content: text, format: 'qrc');
  final hasMsHeader = RegExp(r'^\[\d+,\d+\]', multiLine: true).hasMatch(text);
  if (!hasMsHeader) return (content: text, format: format);
  if (RegExp(r'\(\d+,\d+,\d+\)').hasMatch(text)) {
    final converted = convertNeteaseNewYrc(text).trim();
    if (converted.isEmpty) return null;
    return (content: converted, format: 'yrc');
  }
  return (content: _rewriteMsHeaders(text), format: 'yrc');
}

/// 翻译 / 罗马音的格式归一化（服务端可能给新 YRC 或 `[ms,dur]` 行头）。
({String? content, String? format}) _normalizeSubLyric(
  String? raw,
  String? format,
) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return (content: null, format: null);
  if (!RegExp(r'^\[\d+,\d+\]', multiLine: true).hasMatch(text)) {
    return (content: text, format: format);
  }
  if (RegExp(r'\(\d+,\d+,\d+\)').hasMatch(text)) {
    return (
      content: convertNeteaseNewYrcToLrc(text).trim(),
      format: 'lrc',
    );
  }
  return (
    content: _rewriteMsHeaders(text)
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .trim(),
    format: 'lrc',
  );
}

/// `[起始毫秒,时长毫秒]` 行头 → `[m:ss.xxx]`（其余内容保持不变）。
String _rewriteMsHeaders(String text) {
  final out = StringBuffer();
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    final m = RegExp(r'^\[(\d+),(\d+)\](.*)$').firstMatch(line);
    if (m == null) {
      if (line.isNotEmpty) out.writeln(line);
      continue;
    }
    final ms = int.parse(m.group(1)!);
    final minute = ms ~/ 60000;
    final sec = (ms % 60000) ~/ 1000;
    final frac = ms % 1000;
    out.writeln(
      '[${minute.toString().padLeft(2, '0')}:'
      '${sec.toString().padLeft(2, '0')}.'
      '${frac.toString().padLeft(3, '0')}]${m.group(3)}',
    );
  }
  return out.toString().trim();
}
