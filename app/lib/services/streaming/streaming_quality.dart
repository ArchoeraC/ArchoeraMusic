// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 流媒体转码档位 → 服务端参数映射。
///
/// 仅使用**标准参数**以保证对第三方服务端的兼容：
/// - Subsonic 系（Navidrome/Airsonic/Subsonic…）：`format` + `maxBitRate`；
/// - Jellyfin/Emby：`AudioCodec` + `MaxStreamingBitrate`。
/// 自有服务端也走同一标准参数（Rust 转码器输出 MP3），无需私有协议。
library;

class StreamingTranscode {
  const StreamingTranscode(this.format, this.maxBitRateKbps);

  /// `'raw'` = 原文件（不转码）；`'mp3'` = 服务端转码为 MP3（最通用）。
  final String format;

  /// 目标比特率（kbps）；0 = 不限。仅 [format] != `'raw'` 时有意义。
  final int maxBitRateKbps;

  bool get isOriginal => format == 'raw';
}

/// 档位键（`stores/prefs_streaming.dart` 的 [streamingQualityLevels]）→ 参数。
///
/// - `original`：原文件（默认）；
/// - `high`/`medium`/`low`：320/192/128 kbps MP3 转码（通用，兼容其它服务端）。
StreamingTranscode streamingTranscodeFor(String quality) {
  switch (quality) {
    case 'high':
      return const StreamingTranscode('mp3', 320);
    case 'medium':
      return const StreamingTranscode('mp3', 192);
    case 'low':
      return const StreamingTranscode('mp3', 128);
    case 'original':
    default:
      return const StreamingTranscode('raw', 0);
  }
}
