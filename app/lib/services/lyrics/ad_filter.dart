// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 内置元数据/歌词广告清洗（**强内置、全音源、无开关**）。
///
/// 与下载引擎 `app/core/downloader/src/sanitize.rs` 的规则保持一致：第三方
/// /直传音源的歌词与标签常夹带站点推广（「资源来自 XX 云音乐」「获取更多
/// 无损音乐 https://…」、公众号/群号等）。应用内展示同样必须过滤，保证所有
/// 端（各平台客户端 / 下载写标签）行为一致。
///
/// 只收录**强推广信号**，避免误伤正规歌词：含 URL 的行几乎必为推广。
library;

/// 广告/推广特征（小写包含匹配）。
const List<String> kAdMarkers = [
  'http://',
  'https://',
  'www.',
  'music.cnmsb.xin',
  'neko云音乐',
  'neko cloud music',
  'neko music',
  '资源来自',
  '获取更多无损音乐',
  '更多免费无损音乐',
  '关注公众号',
  '微信公众号',
  '扫码关注',
  '交流群',
  'qq群',
  '暂无歌词',
];

/// 文本是否为广告/推广内容（空文本不算）。
bool isAdMetadataText(String text) {
  final t = text.trim().toLowerCase();
  if (t.isEmpty) return false;
  for (final m in kAdMarkers) {
    if (t.contains(m)) return true;
  }
  return false;
}
