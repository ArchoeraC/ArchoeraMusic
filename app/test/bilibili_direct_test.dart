// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Bilibili 直连验证：WBI 搜索 → 详情/分P → AAC 取流。
///
/// 真实网络用例默认跳过：B 站风控/地域/断网都会变成假红或长时间等待。
/// 显式 `ARCHOERA_ONLINE_TEST=1` 才执行。不打印签名直链与二维码 key。
library;

import 'dart:io';

import 'package:archoera_music/apis/bilibili/core/types.dart';
import 'package:archoera_music/services/bilibili/bilibili_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final online = Platform.environment['ARCHOERA_ONLINE_TEST'] == '1';
  final skip = online ? null : '真实网络请求：设 ARCHOERA_ONLINE_TEST=1 启用';

  test('WBI 搜索返回视频并按 AAC 解析可播放直链', () async {
    final api = BilibiliApi();
    final result = await api.searchSongs('原创 音乐', page: 1, limit: 20);
    expect(result.items, isNotEmpty);
    final first = result.items.first;
    expect(first.bilibili?.bvid, isNotEmpty);

    final url = await api.resolvePlayUrl(first, quality: 'hq');
    final uri = Uri.parse(url);
    expect(uri.scheme, 'https');
    expect(uri.host, isNotEmpty);
    expect(uri.userInfo, isEmpty);
  }, skip: skip);

  test('BV 号直接解析为 bvid:cid 身份', () async {
    final api = BilibiliApi();
    final result = await api.searchSongs('BV1Cjxy68EKv');
    expect(result.items.length, 1);
    final item = result.items.first;
    expect(item.bilibili?.bvid, 'BV1Cjxy68EKv');
    expect(item.bilibili?.cid, isNotEmpty);
    expect(item.id.contains(':'), isTrue);
  }, skip: skip);

  test('扫码登录出码（不扫码）', () async {
    final api = BilibiliApi();
    final challenge = await api.qrGenerate();
    expect(challenge.key, isNotEmpty);
    expect(Uri.parse(challenge.url).scheme, 'https');
    final state = await api.qrPoll(challenge.key);
    expect(state, anyOf(BilibiliQrState.waiting, BilibiliQrState.scanned));
  }, skip: skip);

  test('发现页（新歌 / 推荐 / 热门）返回可播放条目', () async {
    final api = BilibiliApi();
    for (final section in ['newSongs', 'recommendations', 'popular']) {
      final page = await api.discovery(section);
      expect(page.items, isNotEmpty, reason: section);
      final first = page.items.first;
      expect(first.source, 'bilibili', reason: section);
      expect(first.bilibili?.bvid, isNotEmpty, reason: section);
    }
  }, skip: skip);

  test('视频评论：aid 定位 + 热门游标分页', () async {
    final api = BilibiliApi();
    final detail = await api.detailByBvid('BV1GJ411x7h7');
    expect(detail.aid, greaterThan(0));
    final aid = '${detail.aid}';

    final first = await api.videoComments(aid, hot: true);
    expect(first.list, isNotEmpty);
    expect(first.total, greaterThan(0));
    expect(first.list.first.text, isNotEmpty);

    final next = first.next;
    expect(next, isNotNull);
    final second = await api.videoComments(aid, hot: true, next: next!);
    expect(second.list, isNotEmpty);
  }, skip: skip);
}
