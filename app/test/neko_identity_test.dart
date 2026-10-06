// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// NekoMusic 客户端标识与媒体请求头注册表单测：版本截断、标识头构造、
// 封面 / 头像 URL 命中（仅本站 API），第三方 CDN 不附加头。

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
      expect(nekoUserAgent, 'ArchoeraMusic/$clientVersion');
      expect(nekoClientValue, 'archoera+$clientVersion');
    });
  });

  group('mediaHeadersForUrl', () {
    test('NekoMusic 封面 / 头像附加 X-Neko-Client（不含 UA）', () {
      for (final url in const [
        'https://music.nekocore.cn/api/music/cover/42',
        'https://music.nekocore.cn/api/user/avatar/7?v=123',
      ]) {
        final h = mediaHeadersForUrl(url);
        expect(h, isNotNull, reason: url);
        expect(h![kNekoClientHeader], startsWith('archoera+'));
        // 站点图片只加标识头，避免与全局浏览器 UA 叠成双头。
        expect(h.containsKey('User-Agent'), isFalse);
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
