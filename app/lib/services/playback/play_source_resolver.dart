// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../netease/track.dart';
import '../source/source_platform.dart';

/// 播放源解析：**播放管线与下载回退共用的唯一实现**。
///
/// 职责：把 [Track] 按 [quality]（档位键 lq/sq/hq/lossless/hi-res）解析为
/// 可播放 URL。`local` 源返回本地路径；其余源走对应平台 API——具体差异由
/// [sourcePlatform] 返回的适配器封装（本文件只做转发与下载回退门禁）。
///
/// 调用方：
///  - 播放管线 `_PlaybackNotifierQueue._resolveSource`（全源，[allowQqMusic] = true）；
///  - 下载回退（`DownloadController`，Rust 解析失败时复用本函数）——
///    **下载器明确不支持 QQMusic**，故回退调用传 [allowQqMusic] = false；
///    该语义由适配器的 [SourcePlatform.downloadFallbackSupported] 能力位体现。
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
  final platform = sourcePlatform(track.source);
  if (!allowQqMusic && !platform.downloadFallbackSupported) {
    log?.call(platform.downloadUnsupportedLog(track));
    return null;
  }
  return platform.resolvePlayUrl(
    ref,
    track,
    quality: quality,
    streamingQuality: streamingQuality,
    log: log,
  );
}
