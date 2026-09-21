// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'app_prefs.dart';

// ── 流媒体域键（streaming. 前缀）──────────────────────────────────
const streamingQualityKey = 'streaming.quality';

/// 流媒体（Subsonic/Jellyfin）转码档位。
///
/// 默认 `original`（原文件，`format=raw&maxBitRate=0`）；其余档位请求服务端
/// **转码为通用 MP3**——`format=mp3` + `maxBitRate` 是 Subsonic 标准参数，
/// Navidrome/Airsonic 等通用服务端均支持；自有服务端也走同一标准参数
/// （Rust 转码器输出 MP3）。Jellyfin/Emby 走 `AudioCodec=mp3` + `MaxStreamingBitrate`。
const streamingQualityLevels = <String>['original', 'high', 'medium', 'low'];

/// 默认档位（原文件）。
const streamingQualityDefault = 'original';

extension StreamingPrefs on AppPrefs {
  /// 流媒体转码档位（非法值回落原文件）。
  String get streamingQuality {
    final v = data[streamingQualityKey];
    return (v is String && streamingQualityLevels.contains(v))
        ? v
        : streamingQualityDefault;
  }

  AppPrefs copyWithStreamingQuality(String value) {
    return AppPrefs(
      initialData: {
        ...data,
        streamingQualityKey: streamingQualityLevels.contains(value)
            ? value
            : streamingQualityDefault,
      },
    );
  }
}
