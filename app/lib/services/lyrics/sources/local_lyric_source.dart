// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 本地歌词来源：优先 Track 内嵌，其次按 id/路径懒查 library.db。
library;

import '../../../apis/lyric/types.dart';
import '../../netease/track.dart';
import '../../scanner/tracks_db.dart';
import '../engine/lyric_source.dart';

class LocalLyricSource implements LyricSource {
  const LocalLyricSource();

  @override
  String get id => 'local';

  @override
  bool get online => false;

  @override
  bool get plainTextFallback => true;

  @override
  Future<LyricMatchResult?> fetch(LyricRequest request) async {
    final track = request.track;
    var raw = track.lyrics;
    if (raw == null || raw.trim().isEmpty) {
      raw = await _loadLocalLyrics(track);
    }
    if (raw == null || raw.trim().isEmpty) return null;
    return LyricMatchResult(platform: 'local', format: 'lrc', content: raw);
  }
}

/// 本地曲目懒查内嵌歌词：优先按 id，回退按本地路径。
///
/// 列表查询已不携带 lyrics（见 `tracks_db.dart` 的显式列），仅在需要歌词时
/// 打开 library.db 单行查询；非本地曲目 / 查询失败返回 null。
Future<String?> _loadLocalLyrics(Track track) async {
  if (track.source != 'local' && (track.localPath ?? '').isEmpty) return null;
  TracksDb? db;
  try {
    db = TracksDb.open();
    final byId = track.id.isNotEmpty ? db.lyricsById(track.id) : null;
    if (byId != null && byId.trim().isNotEmpty) return byId;
    final path = track.localPath;
    if (path != null && path.isNotEmpty) return db.lyricsByPath(path);
    return byId;
  } catch (_) {
    return null;
  } finally {
    db?.close();
  }
}
