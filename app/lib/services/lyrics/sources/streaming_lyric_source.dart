// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 流媒体歌词来源：向曲目所属服务器直取（Subsonic / Jellyfin）。
///
/// - 服务器返回歌词（内嵌扫描）→ 直接用。
/// - 服务器为 ArchoeraMusic 且曲库无内嵌歌词时，返回扩展标记
///   [StreamingLyrics.fetchOnline]，此时由**客户端**（本机）自行在线补全：
///   按用户来源顺序查询 netease/qqmusic/kugou。该扩展仅我方服务端 + 我方
///   客户端之间生效，标准 Subsonic 客户端不受影响。
/// - 其它情况返回 null（走播放页空态）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../apis/lyric/kugou.dart';
import '../../../apis/lyric/netease.dart';
import '../../../apis/lyric/qqmusic.dart';
import '../../../apis/lyric/types.dart';
import '../../netease/track.dart';
import '../../streaming/streaming_client.dart';
import '../../streaming/streaming_provider.dart';
import '../../../stores/app_prefs.dart';
import '../engine/lyric_source.dart';

class StreamingLyricSource implements LyricSource {
  StreamingLyricSource(this._ref);

  final Ref _ref;

  @override
  String get id => 'streaming';

  @override
  bool get online => false;

  @override
  bool get plainTextFallback => false;

  @override
  Future<LyricMatchResult?> fetch(LyricRequest request) async {
    final track = request.track;
    final serverId = track.serverId;
    final originalId = track.originalId;
    if (serverId == null || originalId == null || originalId.isEmpty) {
      return null;
    }
    final cfg = _ref
        .read(streamingProvider.notifier)
        .serverConfigById(serverId);
    if (cfg == null) return null;
    try {
      final lyrics = await StreamingClient(cfg).getLyrics(
        originalId,
        artist: track.artistNames,
        title: track.title,
      );
      if (lyrics.hasLrc) {
        return LyricMatchResult(
          platform: 'streaming',
          format: 'lrc',
          content: lyrics.lrc!,
        );
      }
      // 仅我方服务端会给出该标记：客户端自行在线补全。
      if (lyrics.fetchOnline && cfg.isArchoeraServer) {
        return await _onlineFallback(track, preferRich: request.preferRich);
      }
    } catch (_) {
      // 无歌词 / 网络失败 → 空态
    }
    return null;
  }

  /// 按用户来源顺序在本机查询在线歌词（服务端无内嵌时的客户端补全）。
  Future<LyricMatchResult?> _onlineFallback(
    Track track, {
    required bool preferRich,
  }) async {
    final prefs = _ref.read(appPrefsProvider);
    for (final platform in prefs.lyricSourceOrder) {
      LyricMatchResult? match;
      try {
        match = switch (platform) {
          'netease' => await nmGetLyricByQuery(track, preferRich: preferRich),
          'qqmusic' => await qmGetLyricByQuery(track, preferRich: preferRich),
          'kugou' => await kgGetLyricByQuery(track, preferRich: preferRich),
          _ => null,
        };
      } catch (_) {
        match = null;
      }
      if (match != null) return match;
    }
    return null;
  }
}
