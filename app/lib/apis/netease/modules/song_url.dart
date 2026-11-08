// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 获取歌曲播放地址（v1 端点，level 而非裸 br，对齐 song_url.ts）
///
/// **必须走 xeapi**（对齐 SPlayer-Next `modules/song_url.ts`）：eapi 通道在
/// 未携带/尚未取得 NMTID 时会被风控直接拒绝，返回
/// `-460 检测到您的网络环境存在风险，请稍后再试`。播放解析通常是冷启动后的
/// 第一个 eapi 请求，正好落在「NMTID 探测期」，于是每次点击都失败；等探测
/// 次数耗尽、客户端自行编出 NMTID 后才恢复——表现为「要点好几次才能播放」。
/// xeapi 是客户端反爬加密通道，不再依赖 eapi 的 NMTID 探测，因此稳定可用。
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmSongUrl = (query, request) {
  final ids = query['id'] ?? query['ids'];
  final data = <String, dynamic>{
    'ids': '[${'$ids'.split(',').join(',')}]',
    'level': query['level'] ?? 'exhigh',
    'encodeType': 'flac',
  };
  return request(
    '/api/song/enhance/player/url/v1',
    data,
    nmCreateOption(query, 'xeapi'),
  );
};
