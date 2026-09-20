// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Neko 曲目元数据补充 / 重写。
///
/// Neko 是**第三方直传**音源，元数据普遍不规范：标题/歌手可能混写、专辑缺失、
/// 封面为上传内嵌图或默认图。而下载引擎把 enqueue 传入的 `title/artist/album`
/// 作为**最高优先级**写进文件标签与文件名（见 Rust `metadata::enrich_file`）。
///
/// 因此入队前用其它音源（NT → KG → QM，按此优先级）以「标题 + 歌手」搜索匹配，
/// 命中即用其规范元数据**重写** Neko 曲目的展示字段（保留 `source='neko'` 与
/// `id`，播放/下载仍走 Neko 直链）。
///
/// 匹配策略保守：要求歌手名归一化后有交集且标题高度相似，避免把翻唱/同名曲
/// 的元数据错误套用；无命中则原样返回。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../stores/providers.dart';
import '../../utils/search_relevance.dart';
import '../netease/track.dart';
import 'neko_standard_lyrics.dart';

class NekoMetadataEnricher {
  NekoMetadataEnricher(this._ref);

  final Ref _ref;

  /// 元数据（标题/歌手/专辑/封面/时长）缓存，按 Neko 曲目 id。
  final Map<String, Track> _metaCache = {};

  /// 元数据 + 标准歌词 缓存（下载路径用）。
  final Map<String, Track> _fullCache = {};

  /// 返回补全/重写后的曲目；无匹配或非 Neko 曲目时原样返回。
  ///
  /// [fetchLyrics] 为 true 时额外**强制重写歌词**（下载写标签用；会多打几次
  /// 标准源歌词请求）；播放展示路径保持 false，避免拖慢起播。
  Future<Track> enrich(Track track, {bool fetchLyrics = false}) async {
    if (track.source != 'neko' || track.id.isEmpty) return track;
    final id = track.id;

    if (fetchLyrics) {
      final cached = _fullCache[id];
      if (cached != null) return cached;
      final result = await _withStandardLyrics(
        await _enrichMeta(track),
      );
      _fullCache[id] = result;
      return result;
    }

    // 播放展示：优先复用已含歌词的全量结果（元数据相同）。
    final cached = _fullCache[id] ?? _metaCache[id];
    if (cached != null) return cached;
    final result = await _enrichMeta(track);
    _metaCache[id] = result;
    return result;
  }

  /// 元数据补充/重写（不取歌词）。
  Future<Track> _enrichMeta(Track track) async {
    for (final source in const ['netease', 'kugou', 'qqmusic']) {
      try {
        final match = await _searchAndMatch(source, track);
        if (match != null) return _rewrite(track, match);
      } catch (_) {
        // 单源失败继续下一源
      }
    }
    return track;
  }

  /// 歌词**强制重写**：Neko 自身歌词常为站点广告/占位/非标准格式，不可信，
  /// 一律改用标准音源（NT→QM→KG）的标准 LRC；取不到则留空由引擎 LRCLIB 兜底。
  Future<Track> _withStandardLyrics(Track track) async {
    try {
      final lyrics = await fetchStandardNekoLyrics(track);
      if (lyrics != null && lyrics.trim().isNotEmpty) {
        return track.copyWithLyrics(lyrics);
      }
    } catch (_) {
      // 歌词补充失败不影响元数据
    }
    return track;
  }

  Future<Track?> _searchAndMatch(String source, Track track) async {
    final query = '${track.title} ${track.artistNames}'.trim();
    if (query.isEmpty) return null;

    final List<Track> items;
    if (source == 'kugou') {
      items = (await _ref
              .read(kugouApiProvider)
              .searchSongs(query, page: 1, limit: 20))
          .items;
    } else if (source == 'qqmusic') {
      items = (await _ref
              .read(qqMusicApiProvider)
              .searchSongs(query, page: 1, limit: 20))
          .items;
    } else {
      items = (await _ref
              .read(neteaseApiProvider)
              .searchSongs(query, offset: 0, limit: 20))
          .items;
    }
    if (items.isEmpty) return null;

    final ranked = sortByRelevance(
      query,
      items,
      (t) => searchRelevanceScore(query, t.title, t.artistNames, t.album?.name),
    );
    for (final candidate in ranked) {
      if (!_titleMatches(track, candidate)) continue;
      if (_artistMatches(track, candidate)) return candidate;
      // 歌手字段缺失（歌手混写在标题里等 Neko 常见情况）：
      // 用「候选歌手名是否出现在查询串中」兜底。
      if (_normArtists(track).isEmpty && _artistInQuery(candidate, query)) {
        return candidate;
      }
    }
    return null;
  }

  /// 候选歌手名是否出现在查询串中（歌手缺失时的兜底判据）。
  static bool _artistInQuery(Track candidate, String query) {
    final q = _norm(query);
    if (q.isEmpty) return false;
    for (final a in _normArtists(candidate)) {
      if (a.isNotEmpty && q.contains(a)) return true;
    }
    return false;
  }

  /// 歌手名归一化后是否有交集（任一歌手命中即可）。
  static bool _artistMatches(Track a, Track b) {
    final na = _normArtists(a);
    final nb = _normArtists(b);
    if (na.isEmpty || nb.isEmpty) return false;
    for (final x in na) {
      if (nb.contains(x)) return true;
    }
    return false;
  }

  /// 标题归一化后相等 / 互相包含。
  static bool _titleMatches(Track a, Track b) {
    final ta = _norm(a.title);
    final tb = _norm(b.title);
    if (ta.isEmpty || tb.isEmpty) return false;
    return ta == tb || ta.contains(tb) || tb.contains(ta);
  }

  static Set<String> _normArtists(Track t) {
    final out = <String>{};
    for (final a in t.artists) {
      final n = _norm(a.name);
      if (n.isNotEmpty) out.add(n);
    }
    return out;
  }

  static final RegExp _strip = RegExp(
    r"[\s\-_/、,，.。·・()（）\[\]【】'`~!?？！&+]+",
  );

  static String _norm(String? s) =>
      (s ?? '').toLowerCase().replaceAll(_strip, '');

  /// 用匹配源的规范元数据重写 Neko 曲目（保留 id / source）。
  static Track _rewrite(Track src, Track match) => Track(
    id: src.id,
    title: match.title.isNotEmpty ? match.title : src.title,
    comment: match.comment,
    artists: match.artists.isNotEmpty ? match.artists : src.artists,
    album: match.album ?? src.album,
    duration: match.duration > 0 ? match.duration : src.duration,
    cover: match.cover ?? src.cover,
    coverOriginal: match.coverOriginal ?? src.coverOriginal,
    source: 'neko',
    quality: match.quality,
  );
}
