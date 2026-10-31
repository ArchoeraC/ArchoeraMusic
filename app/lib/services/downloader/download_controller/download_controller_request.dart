// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../download_controller.dart';

Map<String, dynamic> buildDownloadRequest(
  Track track, {
  String quality = 'hq',
}) {
  final lyrics = track.lyrics?.trim();
  return {
    'trackId': track.id,
    'source': track.source,
    'platformId': track.id,
    'quality': quality,
    'title': track.title,
    'artist': track.artistNames,
    'album': track.album?.name,
    // 强制重写歌词（Neko 等直传源在入队前已取标准 LRC）：引擎按
    // 「enqueue 元数据 > 平台 > 内嵌」合并，非空时覆盖内嵌歌词。
    'lyrics': (lyrics == null || lyrics.isEmpty) ? null : lyrics,
    'extra': downloadPlatform(track.source).requestExtra(track),
  };
}
