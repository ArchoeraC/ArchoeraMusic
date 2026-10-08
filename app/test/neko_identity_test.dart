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

  setUp(nekoResetIdentity);
  tearDown(nekoResetIdentity);

  group('版本读取', () {
    test('自 pubspec 读取并截断构建号为语义版本', () async {
      await loadAppVersion();
      expect(appVersion, isNotEmpty);
      // 0.9.20+5 → 0.9.20
      expect(clientVersion, appVersion.split('+').first);
      expect(clientVersion.contains('+'), isFalse);
      expect(nekoClientValue, 'archoera+$clientVersion');
    });

    test('请求头（主路径）：ArchoeraMusic 本体 UA + X-Neko-Client，UA 非空', () {
      final h = nekoRequestHeaders;
      expect(nekoIdentityUsesFallback, isFalse);
      // 主路径：ArchoeraMusic 本体自报。
      expect(h['User-Agent'], startsWith('ArchoeraMusic/'));
      expect(h['User-Agent'], isNotEmpty);
      expect(h[kNekoClientHeader], 'archoera+$clientVersion');
    });

    test('请求头（回退）：纯 NekoMusic 桌面 UA 形状 + 仍带 X-Neko-Client', () {
      nekoNoteIdentityRejected();
      expect(nekoIdentityUsesFallback, isTrue);
      final h = nekoRequestHeaders;
      // 官方锚定正则：NekoMusic-(windows|macos|linux)/<数字开头的版本>。
      expect(
        h['User-Agent'],
        matches(RegExp(r'^NekoMusic-(windows|macos|linux)/\d')),
      );
      expect(h[kNekoClientHeader], 'archoera+$clientVersion');
      // 不冒名 Android、也不伪装浏览器。
      expect(h['User-Agent'], isNot(contains('android')));
      expect(h['User-Agent'], isNot(contains('Mozilla')));
    });
  });

  group('mediaHeadersForUrl', () {
    test('NekoMusic 封面 / 头像附加标识头与浏览器特征头（不含 UA）', () {
      for (final url in const [
        'https://music.nekocore.cn/api/music/cover/42',
        'https://music.nekocore.cn/api/user/avatar/7?v=123',
      ]) {
        final h = mediaHeadersForUrl(url);
        expect(h, isNotNull, reason: url);
        expect(h![kNekoClientHeader], startsWith('archoera+'));
        // 站点图片走全局浏览器 UA、无法清空 UA；补齐 Accept + Accept-Language
        // 以通过服务端「浏览器完整性」放行（见 neko_identity.dart 注释）。
        expect(h.containsKey('User-Agent'), isFalse);
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
