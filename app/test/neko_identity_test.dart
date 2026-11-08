// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// NekoMusic 出站请求头单测：官方锚定 UA、媒体请求头注册表。
//
// 新协议不再有客户端身份头（X-Neko-Client / X-Neko-Nonce），UA 只用于
// 服务端的 SEO / SPA 表示选择，不参与鉴权。

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/neko/neko_identity.dart';
import 'package:archoera_music/services/source/media_request_headers.dart';
import 'package:archoera_music/utils/app_version.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('版本读取', () {
    test('自 pubspec 读取并截断构建号为语义版本', () async {
      await loadAppVersion();
      expect(appVersion, isNotEmpty);
      // 0.9.20+5 → 0.9.20
      expect(clientVersion, appVersion.split('+').first);
      expect(clientVersion.contains('+'), isFalse);
    });

    test('请求头：官方锚定 PC UA 形状，无身份头', () {
      expect(
        nekoRequestHeaders['User-Agent'],
        matches(RegExp(r'^NekoMusic-PC/\d')),
      );
      expect(nekoRequestHeaders['Accept-Language'], isNotEmpty);
      // 新协议已移除客户端身份 / 防重放头。
      expect(nekoRequestHeaders.containsKey('X-Neko-Client'), isFalse);
      expect(nekoRequestHeaders.containsKey('X-Neko-Nonce'), isFalse);
      // 不冒名 Android、也不伪装浏览器。
      expect(nekoRequestHeaders['User-Agent'], isNot(contains('android')));
      expect(nekoRequestHeaders['User-Agent'], isNot(contains('Mozilla')));
    });
  });

  group('mediaHeadersForUrl', () {
    test('NekoMusic 封面 / 头像只补图片头（不含 UA / 身份头）', () {
      for (final url in const [
        'https://music.nekocore.cn/api/music/cover/42',
        'https://music.nekocore.cn/api/user/avatar/7?v=123',
      ]) {
        final h = mediaHeadersForUrl(url);
        expect(h, isNotNull, reason: url);
        expect(h!.containsKey('User-Agent'), isFalse);
        expect(h.containsKey('X-Neko-Client'), isFalse);
        expect(h['Accept'], isNotEmpty);
        expect(h['Accept-Language'], isNotEmpty);
      }
    });

    test('第三方 CDN / 非法 URL 不附加头', () {
      expect(mediaHeadersForUrl('https://p3.music.126.net/a.jpg'), isNull);
      expect(mediaHeadersForUrl('https://y.gtimg.cn/a.jpg'), isNull);
      expect(mediaHeadersForUrl('http://[::1'), isNull);
      expect(mediaHeadersForUrl(''), isNull);
    });
  });
}
