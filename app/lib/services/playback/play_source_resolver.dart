// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../netease/track.dart';
import '../streaming/streaming_client.dart';
import '../streaming/streaming_http.dart';
import '../streaming/streaming_provider.dart';
import '../streaming/streaming_quality.dart';
import '../streaming/streaming_session.dart';
import '../../stores/app_prefs.dart';
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
  /// 流媒体转码档位覆盖（null = 读全局偏好）。下载走 `'original'` 强制原文件。
  String? streamingQuality,
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
  if (track.source == 'neko') {
    // 实验性音源：Neko 音频直链（id 即服务器曲目 id）。
    return ref.read(nekoApiProvider).resolvePlayUrl(track, quality: quality);
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
    final sq = streamingQuality ?? ref.read(appPrefsProvider).streamingQuality;
    final client = StreamingClient(cfg);
    final url = await client.getStreamUrl(
      originalId,
      playSessionId: sessionIdForTrack(track.id),
      streamingQuality: sq,
    );
    if (streamingTranscodeFor(sq).isOriginal) return url;
    // 兼容性：部分服务端未启用转码，会以 HTTP 200 + JSON 错误响应（Navidrome 实测）。
    // 探测一次；不可用则该服务器记入缓存并回退原文件，避免每次播放都拿到坏 URL。
    final usable = await _streamTranscodeUsable(cfg.id, url);
    if (usable) return url;
    log?.call('流媒体服务端未启用转码，回退原文件: ${track.title}');
    return client.getStreamUrl(
      originalId,
      playSessionId: sessionIdForTrack(track.id),
      streamingQuality: 'original',
    );
  }
  log?.call('暂不支持的播放源: ${track.source}（${track.title}）');
  return null;
}

/// 流媒体服务端是否支持转码（按 serverId 缓存；失败只探测一次，避免重复坏 URL）。
final Map<String, bool> _streamTranscodeSupport = <String, bool>{};

Future<bool> _streamTranscodeUsable(String serverId, String url) async {
  final known = _streamTranscodeSupport[serverId];
  if (known != null) return known;
  final ok = await _probeAudioUrl(url);
  _streamTranscodeSupport[serverId] = ok;
  return ok;
}

/// 轻量探测 URL 是否返回音频：Range 取前 64B。
/// 常见失败形态：服务端未启用转码 → `HTTP 200 application/json`（Navidrome 实测）。
Future<bool> _probeAudioUrl(String url) async {
  try {
    final res = await fetchWithTimeout(
      url,
      headers: const {'Range': 'bytes=0-63'},
      timeout: const Duration(seconds: 10),
    );
    if (res.statusCode >= 400) return false;
    final buf = BytesBuilder(copy: false);
    await for (final chunk in res) {
      buf.add(chunk);
      if (buf.length >= 64) break;
    }
    final ct = res.headers.contentType?.mimeType.toLowerCase() ?? '';
    if (ct.startsWith('audio/') || ct == 'application/octet-stream') return true;
    return _looksLikeAudio(buf.takeBytes());
  } catch (_) {
    return false;
  }
}

bool _looksLikeAudio(List<int> b) {
  if (b.length < 4) return false;
  if (b[0] == 0x66 && b[1] == 0x4C && b[2] == 0x61 && b[3] == 0x43) return true; // fLaC
  if (b[0] == 0x4F && b[1] == 0x67 && b[2] == 0x67 && b[3] == 0x53) return true; // OggS
  if (b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) return true; // ID3v2
  if (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) return true; // MPEG frame sync
  if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46) return true; // RIFF
  return false;
}
