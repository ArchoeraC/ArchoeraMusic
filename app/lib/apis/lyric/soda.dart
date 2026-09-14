// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水歌词匹配（对齐 apis/lyric/kugou.dart 范式）。
///
/// - [sodaGetLyricByPlatformId] 按 track id 直取：SEO `seo_track` 的
///   `lyric.content` 即 **KRC 逐字**（`[行start,dur]<字start,dur,?>字…`），
///   直接以 format `krc` 返回，交给现有 KRC→逐字渲染管线。
/// - [sodaGetLyricByQuery] 元数据 → search → 最佳候选 → 直取。
library;

import '../../services/netease/track.dart';
import '../logger.dart';
import '../runtime.dart';
import '../soda/api.dart';
import 'fingerprint.dart';
import 'types.dart';
import 'utils.dart';

/// 按汽水 track id 直取 KRC 逐字歌词。
Future<LyricMatchResult?> sodaGetLyricByPlatformId(String id) async {
  if (id.isEmpty) return null;
  final cached = getRuntime().lyricCache.get('soda', id);
  if (cached != null) return LyricMatchResult.fromJson(cached);

  try {
    final body = await sodaCall('seo_track', {'id': id});
    if (body is! Map || body['code'] != 200) return null;
    final content = body['lyric']?.toString().trim();
    if (content == null || content.isEmpty) return null;

    final result = LyricMatchResult(
      platform: 'soda',
      format: 'krc',
      content: content,
    );
    getRuntime().lyricCache.set('soda', id, result.toJson());
    return result;
  } catch (err) {
    coreLog.warn('[lyric:soda] getByPlatformId($id) failed: $err');
    return null;
  }
}

/// 按 Track 元数据模糊搜索：search → 挑最佳 → 直取歌词。
Future<LyricMatchResult?> sodaGetLyricByQuery(Track track) async {
  final fingerprint = buildFingerprint(track);
  final cached = getRuntime().lyricMatchCache.get(fingerprint, 'soda');
  if (cached != null) return sodaGetLyricByPlatformId(cached.platformId);

  final keyword = buildLyricSearchKeyword(track);
  if (keyword.isEmpty) return null;

  final candidates = <LyricCandidate<Map<String, String>>>[];
  try {
    final body = await sodaCall('search', {
      'keywords': keyword,
      'limit': 25,
      'type': 0,
    });
    if (body is! Map || body['code'] != 200) return null;
    final songs = body['songs'] as List? ?? const [];
    for (final item in songs.whereType<Map>()) {
      candidates.add(
        LyricCandidate<Map<String, String>>(
          name: item['name']?.toString() ?? '',
          artist: item['artist']?.toString() ?? '',
          album: item['album']?.toString(),
          duration: (item['duration'] as num?)?.toInt(),
          extra: {'id': item['id']?.toString() ?? ''},
        ),
      );
    }
  } catch (err) {
    coreLog.warn('[lyric:soda] search("$keyword") failed: $err');
    return null;
  }

  final best = pickBestCandidate(candidates, track);
  coreLog.info(
    '[lyric:soda] fuzzy "$keyword" → ${candidates.length} hits, '
    'best=${best?.name ?? 'none'}',
  );
  if (best == null) return null;
  final id = best.extra['id'] ?? '';
  if (id.isEmpty) return null;
  getRuntime().lyricMatchCache.set(fingerprint, 'soda', id);
  return sodaGetLyricByPlatformId(id);
}
