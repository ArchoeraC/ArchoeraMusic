// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 集中歌词引擎：来源顺序回退 + 统一解码。
///
/// 取代此前散落在 `lyrics_provider` 的平台 `switch`：引擎持有全部
/// [LyricSource]，按「本平台优先 → 用户来源顺序」逐个尝试，命中即解码返回。
/// 本地 / 流媒体等非在线源只用自己的源，不做在线回退。
library;

import '../../../apis/lyric/types.dart';
import '../../netease/track.dart';
import '../lyric_line.dart';
import 'lyric_decoder.dart';
import 'lyric_source.dart';

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
  Future<List<LyricGroup>> resolve(
    Track track, {
    String? trackId,
    required List<String> sourceOrder,
    required bool preferRich,
  }) async {
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
      if (groups.isNotEmpty) return groups;
    }
    return const [];
  }
}
