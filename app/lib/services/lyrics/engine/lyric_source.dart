// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词来源契约：只负责「平台 I/O」，返回未解析的匹配结果。
///
/// 引擎（[LyricsEngine]）统一负责来源顺序、回退、解码与后处理；各来源
/// （netease / qqmusic / kugou / local / streaming）只把平台差异封装在此。
library;

import '../../../apis/lyric/types.dart';
import '../../netease/track.dart';

/// 一次歌词解析请求。
class LyricRequest {
  const LyricRequest({
    required this.track,
    required this.preferRich,
    this.trackId,
  });

  final Track track;

  /// 当前播放曲目的平台 id（可能为 null；来源自行判断是否属于自己）。
  final String? trackId;

  /// 是否逐字（富）格式优先。
  final bool preferRich;
}

/// 歌词来源。
abstract interface class LyricSource {
  /// 稳定 id：与 `Track.source` 对应（'netease'/'qqmusic'/'kugou'/
  /// 'local'/'streaming'）。
  String get id;

  /// 是否在线源：仅在线源参与「来源顺序」回退；本地/流媒体只用自己的源。
  bool get online;

  /// 解码无时间标签纯文本时是否降级为整段静态歌词（仅本地内嵌歌词用）。
  bool get plainTextFallback;

  Future<LyricMatchResult?> fetch(LyricRequest request);
}
