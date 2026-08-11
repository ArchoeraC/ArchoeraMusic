/// 本地曲目（TrackRow）→ UI 播放模型（Track）转换。
library;

import 'dart:io';

import '../netease/track.dart';
import 'library_scanner.dart';
import 'tracks_db.dart';

/// 转换本地曲目为 [Track]（source='local'，无平台品质信息）。
///
/// [cover] 处理：scanner 直写库的 cover 为服务器相对路径
/// `/api/music/cover/{id}`，实际封面文件在 `{dbDir}/cache/covers/{id}.img`，
/// 这里解析为 `file://` 绝对路径供 SongList 封面组件直接读取；无法定位
/// 到文件时原样透传（组件回退占位）。
Track trackFromRow(TrackRow row) {
  return Track(
    id: row.id,
    title: row.title,
    artists: row.artistNames.map((n) => TrackArtist(name: n)).toList(),
    album: (row.albumName?.isNotEmpty ?? false)
        ? TrackAlbum(name: row.albumName!)
        : null,
    duration: row.durationMs,
    cover: _resolveLocalCover(row.cover),
    localPath: row.path,
    lyrics: row.lyrics,
    source: 'local',
  );
}

/// `/api/music/cover/{id}` → `{dbDir}/cache/covers/{id}.img`（file:// 形式）。
String? _resolveLocalCover(String? cover) {
  if (cover == null) return null;
  final m = RegExp(r'^/api/music/cover/(\w+)').firstMatch(cover);
  if (m == null) return cover;
  final dbPath = LibraryScanner.defaultDbPath();
  final idx = dbPath.lastIndexOf('/');
  final dbDir = idx > 0 ? dbPath.substring(0, idx) : '.';
  final file = File('$dbDir/cache/covers/${m.group(1)}.img');
  return file.existsSync() ? 'file://${file.absolute.path}' : cover;
}
