// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Neko 下载歌词**重写**器。
///
/// Neko 服务端已规范曲目元数据（`title` / `artist` / `album` 分字段，对齐官方
/// PC 端 `MusicInfo`），故不再跨源补写元数据；仅下载写标签时把 Neko 自身
/// 歌词（常为站点广告/占位/非标准）替换为标准 LRC（见
/// [fetchStandardNekoLyrics]），取不到则原样返回（Rust 侧再走 LRCLIB 兜底）。
library;

import '../netease/track.dart';
import 'neko_standard_lyrics.dart';

/// 按 Neko 曲目元数据取标准 LRC 并重写；带进程内缓存。
class NekoLyricRewriter {
  final Map<String, Track> _cache = {};

  Future<Track> rewrite(Track track) async {
    if (track.source != 'neko' || track.id.isEmpty) return track;
    final cached = _cache[track.id];
    if (cached != null) return cached;
    Track result = track;
    try {
      final lyrics = await fetchStandardNekoLyrics(track);
      if (lyrics != null && lyrics.trim().isNotEmpty) {
        result = track.copyWithLyrics(lyrics);
      }
    } catch (_) {
      // 歌词补充失败不影响下载
    }
    _cache[track.id] = result;
    return result;
  }
}
