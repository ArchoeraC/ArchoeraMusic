// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// [PlayerFullscreenCover] 冒烟测试：整幅封面铺满给定区域，无封面时走
/// 占位分支且右缘渐隐遮罩正常挂载。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/widgets/player/player_cover.dart';

Widget _wrap(String? cover) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 240,
        height: 320,
        child: PlayerFullscreenCover(cover: cover),
      ),
    ),
  ),
);

void main() {
  testWidgets('无封面时铺满面板并挂载渐隐遮罩', (tester) async {
    await tester.pumpWidget(_wrap(null));
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(PlayerFullscreenCover)),
      const Size(240, 320),
    );
    expect(find.byType(ShaderMask), findsOneWidget);
  });
}
