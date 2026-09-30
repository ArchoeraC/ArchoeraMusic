// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 集中歌词引擎：来源顺序回退 + 统一解码。
///
/// 取代此前散落在 `lyrics_provider` 的平台 `switch`：引擎持有全部
/// [LyricSource]，按「本平台优先 → 用户来源顺序」逐个尝试，命中即解码返回。
/// 本地 / 流媒体等非在线源只用自己的源，不做在线回退。
library;

import '../../../apis/lyric/ttml.dart';
import '../../../apis/lyric/types.dart';
import '../../netease/track.dart';
import '../lyric_line.dart';
import '../ttml_parser.dart';
import 'lyric_decoder.dart';
import 'lyric_source.dart';

/// AMLL DB 覆盖歌词支持的平台目录（与 `apis/lyric/ttml.dart` 的 `%p` 一致）。
const Set<String> _ttmlPlatforms = {'netease', 'qqmusic'};

/// TTML 覆盖等待预算：超时先用平台歌词，抓取在后台继续（成功即写缓存）。
const int kTtmlOverlayBudgetMs = 4000;

class LyricsEngine {
  LyricsEngine(List<LyricSource> sources)
    : _byId = {for (final s in sources) s.id: s};

  final Map<String, LyricSource> _byId;

  /// 按「本平台优先 → 用户来源顺序」排出候选来源。
  ///
  /// 非在线源（local / streaming）只返回自身；未知来源返回空（无歌词）。
  List<LyricSource> orderedSources(String trackSource, List<String> sourceOrder) {
    final own = _byId[trackSource];
    if (own == null || !own.online) {
      return own == null ? const [] : [own];
    }
    final out = <LyricSource>[own];
    for (final id in sourceOrder) {
      if (id == trackSource) continue;
      final source = _byId[id];
      if (source != null && source.online) out.add(source);
    }
    return out;
  }

  /// 解析当前曲目的歌词组；全部来源无结果时返回空列表。
  ///
  /// [enableTtmlOverlay] 为真时优先返回 AMLL DB TTML 覆盖（对齐 AMLL 把
  /// `ttml` 排在格式优先级首位）；TTML 抓取与平台歌词请求**并行**发起
  /// （平台源的 prefetch 会复用同一 inflight Future），并在
  /// [kTtmlOverlayBudgetMs] 内等待——超时先用平台歌词，抓取在后台继续。
  Future<List<LyricGroup>> resolve(
    Track track, {
    String? trackId,
    required List<String> sourceOrder,
    required bool preferRich,
    bool enableTtmlOverlay = false,
    String preferredLang = 'zh-CN',
  }) async {
    final overlay =
        enableTtmlOverlay ? _fetchTtmlText(track, trackId) : null;

    var platform = const <LyricGroup>[];
    for (final source in orderedSources(track.source, sourceOrder)) {
      LyricMatchResult? match;
      try {
        match = await source.fetch(
          LyricRequest(track: track, trackId: trackId, preferRich: preferRich),
        );
      } catch (_) {
        // 单来源失败不阻塞回退（与旧逐平台实现一致）。
        continue;
      }
      if (match == null) continue;
      final groups = decodeLyricGroups(
        match,
        plainTextFallback: source.plainTextFallback,
      );
      if (groups.isNotEmpty) {
        platform = groups;
        break;
      }
    }

    if (overlay != null) {
      String? ttml;
      try {
        ttml = await overlay.timeout(
          const Duration(milliseconds: kTtmlOverlayBudgetMs),
          onTimeout: () => null,
        );
      } catch (_) {
        ttml = null;
      }
      if (ttml != null && ttml.trim().isNotEmpty) {
        final groups = parseTtmlLyrics(ttml, preferredLang: preferredLang);
        if (groups.isNotEmpty) return groups;
      }
    }
    return platform;
  }

  /// 发起 AMLL DB TTML 抓取；平台不支持 / 无候选 id 时返回 null（不请求）。
  ///
  /// 候选 id 与平台歌词预热保持一致：netease → 数字 id；qqmusic → mid（若有）
  /// 再回落数字 id（AMLL DB 里两种 key 都可能存在）。
  Future<String?>? _fetchTtmlText(Track track, String? trackId) {
    final platform = track.source;
    if (!_ttmlPlatforms.contains(platform)) return null;
    final ids = <String>[];
    if (platform == 'qqmusic') {
      final mid = track.qqmusic?.mid;
      if (mid != null && mid.isNotEmpty) ids.add(mid);
    }
    if (trackId != null && trackId.isNotEmpty) ids.add(trackId);
    if (ids.isEmpty) return null;
    try {
      return fetchTTMLOverlay(platform, ids);
    } catch (_) {
      return null;
    }
  }
}
