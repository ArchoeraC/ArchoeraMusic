// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QQMusic 歌词来源（薄适配：把 Track/请求映射到 apis/lyric/qqmusic.dart）。
library;

import '../../../apis/lyric/qqmusic.dart';
import '../../../apis/lyric/types.dart';
import '../engine/lyric_source.dart';

class QqmusicLyricSource implements LyricSource {
  const QqmusicLyricSource();

  @override
  String get id => 'qqmusic';

  @override
  bool get online => true;

  @override
  bool get plainTextFallback => false;

  @override
  Future<LyricMatchResult?> fetch(LyricRequest request) {
    final track = request.track;
    final trackId = request.trackId;
    if (track.source == 'qqmusic' && trackId != null && trackId.isNotEmpty) {
      return qmGetLyricByPlatformId(
        trackId,
        mid: track.qqmusic?.mid,
        preferRich: request.preferRich,
      );
    }
    return qmGetLyricByQuery(track, preferRich: request.preferRich);
  }
}
