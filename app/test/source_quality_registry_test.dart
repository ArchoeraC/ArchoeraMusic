// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 音质选择注册表：各源可选档位裁剪（`SourcePlatform.availableQualities`）与
// Neko 详情音质标签（`qualityLabel` + 异步 `maxQualityProvider`）。

import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations_zh.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/source/source_platform.dart';

void main() {
  final zh = AppLocalizationsZh();

  Track nekoTrack() => Track.fromNekoSong({'id': 7, 'title': 'x'});

  group('音质选择注册表', () {
    test('默认源（NT / 未知）为全档位', () {
      expect(sourcePlatform('netease').supportedQualities, audioQualityLevels);
      expect(
        sourcePlatform('netease').availableQualities(
          const Track(id: '1', title: 'x'),
        ),
        audioQualityLevels,
      );
      expect(
        sourcePlatform('__unknown__').availableQualities(
          const Track(id: '1', title: 'x'),
        ),
        audioQualityLevels,
      );
      expect(sourcePlatform('netease').maxQualityProvider(
        const Track(id: '1', title: 'x'),
      ), isNull);
    });

    test('Neko：四档去重（无 sq）并按 maxQuality 裁剪', () {
      final p = sourcePlatform('neko');
      expect(p.supportedQualities, const ['lq', 'hq', 'lossless', 'hi-res']);
      expect(p.maxQualityProvider(nekoTrack()), isNotNull);
      final t = nekoTrack();
      // 未知最高档 → 全档位
      expect(p.availableQualities(t), const ['lq', 'hq', 'lossless', 'hi-res']);
      expect(p.availableQualities(t, maxQuality: 'standard'), const ['lq']);
      expect(p.availableQualities(t, maxQuality: 'hq'), const ['lq', 'hq']);
      expect(
        p.availableQualities(t, maxQuality: 'sq'),
        const ['lq', 'hq', 'lossless'],
      );
      expect(
        p.availableQualities(t, maxQuality: 'hires'),
        const ['lq', 'hq', 'lossless', 'hi-res'],
      );
    });

    test('Neko：详情音质标签取实际最高档；未知不展示', () {
      final p = sourcePlatform('neko');
      final t = nekoTrack();
      expect(p.qualityLabel(zh, t, maxQuality: 'standard'), 'LQ');
      expect(p.qualityLabel(zh, t, maxQuality: 'hq'), 'HQ');
      expect(p.qualityLabel(zh, t, maxQuality: 'sq'), 'Lossless');
      expect(p.qualityLabel(zh, t, maxQuality: 'hires'), 'Hi-Res');
      // 未取到最高档（离线 / 未升级）→ 不展示，避免误导
      expect(p.qualityLabel(zh, t), isNull);
    });

    test('KG：覆写裁剪（无品质 hash → 空档位）', () {
      const noHash = Track(
        id: '1',
        title: 'x',
        source: 'kugou',
        kugou: KugouTrackInfo(hash: 'h'),
      );
      expect(sourcePlatform('kugou').availableQualities(noHash), isEmpty);
      expect(
        sourcePlatform('kugou').availableQualities(
          const Track(id: '1', title: 'x'),
        ),
        audioQualityLevels,
      );
    });
  });
}
