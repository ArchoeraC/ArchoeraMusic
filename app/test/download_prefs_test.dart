import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/app_prefs.dart';

void main() {
  group('downloadDynamicFingerprint 开关', () {
    test('默认关闭（持久化指纹）', () {
      final prefs = AppPrefs();
      expect(prefs.downloadDynamicFingerprint, isFalse);
    });

    test('copyWithDownloadDynamicFingerprint 读写', () {
      final on = AppPrefs().copyWithDownloadDynamicFingerprint(true);
      expect(on.downloadDynamicFingerprint, isTrue);
      final off = on.copyWithDownloadDynamicFingerprint(false);
      expect(off.downloadDynamicFingerprint, isFalse);
      // 其余下载字段不受影响
      expect(on.downloadMaxConcurrent, 3);
      expect(on.downloadQuality, 'hq');
    });

    test('与设备指纹共存（开关不触碰 downloaderIdentity）', () {
      final prefs = AppPrefs()
          .copyWithDownloaderIdentity('{"kgMid":"1"}')
          .copyWithDownloadDynamicFingerprint(true);
      expect(prefs.downloadDynamicFingerprint, isTrue);
      expect(prefs.downloaderIdentity, '{"kgMid":"1"}');
    });
  });
}
