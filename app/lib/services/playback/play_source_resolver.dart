// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../netease/track.dart';
import '../streaming/streaming_client.dart';
import '../streaming/streaming_provider.dart';
import '../streaming/streaming_session.dart';
import '../../stores/providers.dart';

/// 播放源解析：**播放管线与下载回退共用的唯一实现**。
///
/// 职责：把 [Track] 按 [quality]（档位键 lq/sq/hq/lossless/hi-res）解析为
/// 可播放 URL。`local` 源返回本地路径；其余源走对应平台 API。
///
/// 调用方：
///  - 播放管线 `_PlaybackNotifierQueue._resolveSource`（全源，[allowQqMusic] = true）；
///  - 下载回退（`DownloadController`，Rust 解析失败时复用本函数）——
///    **下载器明确不支持 QQMusic**，故回退调用传 [allowQqMusic] = false。
///
/// [log] 可选诊断日志回调（播放器传自身 `_log`，下载器传 debugPrint 包装）。
Future<String?> resolvePlaySource(
  Ref ref,
  Track track, {
  required String quality,
  bool allowQqMusic = true,
  void Function(String message)? log,
}) async {
  if (track.source == 'local') {
    final p = track.localPath;
    if (p == null || p.isEmpty) {
      log?.call('缺少本地文件路径: ${track.title}');
      return null;
    }
    return p;
  }
  if (track.source == 'kugou' && track.kugou != null) {
    return ref
        .read(kugouApiProvider)
        .resolvePlayUrl(track.kugou!, quality: quality);
  }
  if (track.source == 'netease') {
    return ref
        .read(neteaseApiProvider)
        .resolvePlayUrl(track.id, quality: quality);
  }
  if (track.source == 'qqmusic') {
    if (!allowQqMusic) {
      log?.call('下载回退不支持 QQMusic: ${track.title}');
      return null;
    }
    return ref.read(qqMusicApiProvider).resolvePlayUrl(track, quality: quality);
  }
  if (track.source == 'soda') {
    return ref.read(sodaApiProvider).resolvePlayUrl(track, quality: quality);
  }
  if (track.source == 'streaming') {
    final serverId = track.serverId;
    final originalId = track.originalId;
    if (serverId == null || originalId == null || originalId.isEmpty) {
      log?.call('流媒体曲目缺少 serverId/originalId: ${track.title}');
      return null;
    }
    final cfg = ref.read(streamingProvider.notifier).serverConfigById(serverId);
    if (cfg == null) {
      log?.call('流媒体服务器不存在: $serverId（${track.title}）');
      return null;
    }
    return StreamingClient(
      cfg,
    ).getStreamUrl(originalId, playSessionId: sessionIdForTrack(track.id));
  }
  log?.call('暂不支持的播放源: ${track.source}（${track.title}）');
  return null;
}
