// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Bilibili 登录态直连验证（收藏夹 / 历史 / 关注 / 评论 / FLAC / 杜比）。
///
/// 默认跳过；需要真实大会员 Cookie 时显式运行：
///
/// ```bash
/// ARCHOERA_ONLINE_TEST=1 \
/// ARCHOERA_BILI_COOKIE='SESSDATA=…; bili_jct=…; DedeUserID=…; buvid3=…' \
/// flutter test test/bilibili_vip_test.dart
/// ```
///
/// Cookie 只从环境变量读取，不落盘、不入库。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/apis/runtime.dart';
import 'package:archoera_music/services/bilibili/bilibili_api.dart';

class _EnvSessionStore implements SessionStore {
  _EnvSessionStore(this.cookies);

  final Map<String, String> cookies;

  @override
  Map<String, String> get(String platform) =>
      platform == 'bilibili' ? Map.of(cookies) : const {};

  @override
  void save(String platform, Map<String, String> value) {
    if (platform == 'bilibili') cookies.addAll(value);
  }

  @override
  void clear(String platform) {
    if (platform == 'bilibili') cookies.clear();
  }

  @override
  bool get isLocked => false;
}

Map<String, String> _parseCookieHeader(String raw) {
  final out = <String, String>{};
  for (final part in raw.split(';')) {
    final item = part.trim();
    final eq = item.indexOf('=');
    if (eq <= 0) continue;
    final name = item.substring(0, eq).trim();
    final value = item.substring(eq + 1).trim();
    if (name.isNotEmpty && value.isNotEmpty) out[name] = value;
  }
  return out;
}

void main() {
  final online = Platform.environment['ARCHOERA_ONLINE_TEST'] == '1';
  final rawCookie = Platform.environment['ARCHOERA_BILI_COOKIE'] ?? '';
  final cookies = _parseCookieHeader(rawCookie);
  final skip = !online
      ? '真实网络请求：设 ARCHOERA_ONLINE_TEST=1 启用'
      : cookies['SESSDATA'] == null
      ? '登录态用例：设 ARCHOERA_BILI_COOKIE 启用'
      : null;

  test(
    '登录态：资料 / 评论',
    () async {
      setRuntime(runtime: ApisRuntime(sessionStore: _EnvSessionStore(cookies)));
      final api = BilibiliApi();
      await api.refreshProfile();
      expect(api.isLoggedIn, isTrue);
      expect(api.profile?.mid, isNotEmpty);
      expect(api.profile?.nickname, isNotEmpty);

      final detail = await api.detailByBvid('BV1GJ411x7h7');
      final track = api.trackForPart(detail, detail.parts.first);
      final aid = await api.commentTarget(track);
      expect(aid, isNotNull);
      final comments = await api.videoComments(aid!, hot: true);
      expect(comments.list, isNotEmpty);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    '大会员：FLAC / 杜比取流',
    () async {
      setRuntime(runtime: ApisRuntime(sessionStore: _EnvSessionStore(cookies)));
      final api = BilibiliApi();
      await api.refreshProfile();
      expect(api.profile?.isVip, isTrue, reason: '该 Cookie 不是大会员');

      // 有 Hi-Res 无损音轨的稿件。
      final flacDetail = await api.detailByBvid('BV1ebKE6oEjy');
      final flacTrack = api.trackForPart(flacDetail, flacDetail.parts.first);
      final flacUrl = await api.resolvePlayUrl(flacTrack, quality: 'lossless');
      expect(Uri.parse(flacUrl).path, contains('30251'));

      // 有杜比全景声（无 FLAC）的稿件。
      final dolbyDetail = await api.detailByBvid('BV1kX4y197P4');
      final dolbyTrack = api.trackForPart(dolbyDetail, dolbyDetail.parts.first);
      final dolbyUrl = await api.resolvePlayUrl(dolbyTrack, quality: 'hi-res');
      expect(Uri.parse(dolbyUrl).path, contains('30250'));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
