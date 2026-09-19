// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Netease 歌词来源（薄适配：把 Track/请求映射到 apis/lyric/netease.dart）。
library;

import '../../../apis/lyric/netease.dart';
import '../../../apis/lyric/types.dart';
import '../engine/lyric_source.dart';

class NeteaseLyricSource implements LyricSource {
  const NeteaseLyricSource();

  @override
  String get id => 'netease';

  @override
  bool get online => true;

  @override
  bool get plainTextFallback => false;

  @override
  Future<LyricMatchResult?> fetch(LyricRequest request) {
    final trackId = request.trackId;
    if (request.track.source == 'netease' &&
        trackId != null &&
        trackId.isNotEmpty) {
      return nmGetLyricByPlatformId(trackId, preferRich: request.preferRich);
    }
    return nmGetLyricByQuery(request.track, preferRich: request.preferRich);
  }
}
