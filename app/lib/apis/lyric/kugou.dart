// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Kugou 歌词匹配（对齐 apis/common/lyric/kugou.ts）。
///
/// 两个入口：
/// - [kgGetLyricByPlatformId] 按 hash 直取（kugou 的主键是 hash，不是数字 id；
///   单 hash 无 name/duration，服务端命中率低，建议走 getByQuery）
/// - [kgGetLyricByQuery] search → pickBestCandidate → 单次请求拿歌词
///
/// 返回只带原生格式文本（krc / lrc + 翻译 / 罗马音），不做解析，交给渲染端。
library;

import '../../services/netease/track.dart';
import '../kugou/api.dart';
import '../logger.dart';
import '../runtime.dart';
import 'format.dart';
import 'match.dart';
import 'types.dart';

/// Kugou lyric 接口强依赖 hash + name + duration 三者：
/// 只有 hash 时服务端 candidates 基本为空，必须把 name/duration 一并传过去。
Future<LyricMatchResult?> _fetchLyric({
  required String hash,
  String? name,
  int? durationMs,
  bool preferRich = true,
}) async {
  final cachePlatform = lyricCachePlatform('kugou', preferRich: preferRich);
  final cached = getRuntime().lyricCache.get(cachePlatform, hash);
  if (cached != null) return LyricMatchResult.fromJson(cached);

  try {
    final body = await kgCall('lyric', {
      'hash': hash,
      'name': name ?? '',
      'duration': durationMs != null ? (durationMs / 1000).round() : 0,
    });
    if (body is! Map) return null;
    if (body['code'] != 200) {
      coreLog.warn(
        '[lyric:kugou] fetchLyric($hash) code=${body['code']}: '
        '${body['message'] ?? 'no message'}',
      );
      return null;
    }

    final main = pickLyricFormat(
      [
        LyricFormatCandidate(
          content: body['krc']?.toString(),
          format: 'krc',
          wordByWord: true,
        ),
        LyricFormatCandidate(content: body['lrc']?.toString(), format: 'lrc'),
      ],
      preferRich: preferRich,
    );
    if (main == null) return null;

    final trans = body['trans']?.toString().trim();
    final roma = body['roma']?.toString().trim();

    final result = LyricMatchResult(
      platform: 'kugou',
      format: main.format,
      content: main.content,
      translation: (trans == null || trans.isEmpty) ? null : trans,
      translationFormat: (trans == null || trans.isEmpty) ? null : 'lrc',
      romaji: (roma == null || roma.isEmpty) ? null : roma,
      romajiFormat: (roma == null || roma.isEmpty) ? null : 'lrc',
    );
    getRuntime().lyricCache.set(cachePlatform, hash, result.toJson());
    return result;
  } catch (err) {
    coreLog.warn('[lyric:kugou] fetchLyric($hash) failed: $err');
    return null;
  }
}

/// 按 Kugou hash 直取（只有 hash 时用；精度受限）
Future<LyricMatchResult?> kgGetLyricByPlatformId(
  String hash, {
  bool preferRich = true,
}) => _fetchLyric(hash: hash, preferRich: preferRich);

/// 按 Track 元数据模糊搜索：search → 挑最佳 → 单次请求歌词
Future<LyricMatchResult?> kgGetLyricByQuery(
  Track track, {
  bool preferRich = true,
}) {
  return fetchMatchedLyric(
    platform: 'kugou',
    track: track,
    idOf: (extra) => extra['hash'] ?? '',
    byId: (hash, extra) => _fetchLyric(
      hash: hash,
      name: _nonEmpty(extra['name']) ?? track.title,
      durationMs: int.tryParse(extra['duration'] ?? '') ?? track.duration,
      preferRich: preferRich,
    ),
    search: (keyword) async {
      final candidates = <LyricCandidate<Map<String, String>>>[];
      try {
        final body = await kgCall('search', {'keywords': keyword, 'limit': 25});
        if (body is! Map || body['code'] != 200) return candidates;
        final songs = body['songs'] as List? ?? const [];
        for (final item in songs) {
          final song = (item as Map).cast<String, dynamic>();
          candidates.add(
            LyricCandidate<Map<String, String>>(
              name: song['name']?.toString() ?? '',
              artist: song['artist']?.toString() ?? '',
              album: song['album']?.toString(),
              duration: (song['duration'] as num?)?.toInt(),
              extra: {
                'hash': song['hash']?.toString() ?? '',
                'name': song['name']?.toString() ?? '',
                'duration': '${song['duration'] ?? ''}',
              },
            ),
          );
        }
      } catch (err) {
        coreLog.warn('[lyric:kugou] search("$keyword") failed: $err');
      }
      return candidates;
    },
    logMatch: (keyword, hits, best) => coreLog.info(
      '[lyric:kugou] fuzzy "$keyword" → $hits hits, best=${best ?? 'none'}',
    ),
  );
}

String? _nonEmpty(String? s) => (s == null || s.isEmpty) ? null : s;
