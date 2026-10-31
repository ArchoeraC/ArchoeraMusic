// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 红心写操作源守卫：无收藏适配器的源（B 站 / 本地 / 流媒体）不得回退写入 NT。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/stores/providers.dart';

void main() {
  group('LikeController 源守卫', () {
    test('B 站 / 本地曲目：isLiked=false，toggle 直接失败且不污染任何分桶', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(likeControllerProvider);

      const bilibili = Track(
        id: 'BV1Cjxy68EKv:123',
        title: 'B 站曲目',
        source: 'bilibili',
      );
      const local = Track(id: '/tmp/a.flac', title: '本地曲目', source: 'local');

      for (final track in [bilibili, local]) {
        expect(ctrl.isLiked(track), isFalse, reason: track.source);
        expect(await ctrl.toggle(track), isFalse, reason: track.source);
        expect(ctrl.idsFor(track.source), isEmpty, reason: track.source);
      }
      // 不得把 B 站 / 本地键写进网易云集合。
      expect(ctrl.idsFor('netease'), isEmpty);
    });
  });
}
