// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Kugou 歌词来源（薄适配：把 Track/请求映射到 apis/lyric/kugou.dart）。
///
/// Kugou 主键是 hash 且接口强依赖 name+duration，统一走 query 链路。
library;

import '../../../apis/lyric/kugou.dart';
import '../../../apis/lyric/types.dart';
import '../engine/lyric_source.dart';

class KugouLyricSource implements LyricSource {
  const KugouLyricSource();

  @override
  String get id => 'kugou';

  @override
  bool get online => true;

  @override
  bool get plainTextFallback => false;

  @override
  Future<LyricMatchResult?> fetch(LyricRequest request) =>
      kgGetLyricByQuery(request.track, preferRich: request.preferRich);
}
