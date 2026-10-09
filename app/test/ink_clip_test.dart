// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// [InkClip] 回归测试。
///
/// `InkClip` 的存在意义是**把列表行 InkWell 的 ink（悬停/水波纹）裁剪到滚动
/// 视口内**，修复「半露出视口的行其悬停高亮越界画到列表上下边界之外」。若有人
/// 把内部的透明 `Material` + `Clip.hardEdge` 去掉，本测试会失败以阻止回归。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/widgets/common/ink_clip.dart';

void main() {
  testWidgets('InkClip 用透明 Material + hardEdge 裁剪包裹子树', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: InkClip(child: Text('x'))),
      ),
    );
    final material = tester.widget<Material>(
      find
          .descendant(of: find.byType(InkClip), matching: find.byType(Material))
          .first,
    );
    expect(material.type, MaterialType.transparency);
    expect(material.clipBehavior, Clip.hardEdge);
    expect(material.shape, isNull);
  });

  testWidgets('InkClip 传 borderRadius 时以圆角形状裁剪', (tester) async {
    const radius = BorderRadius.all(Radius.circular(12));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: InkClip(borderRadius: radius, child: Text('x')),
        ),
      ),
    );
    final material = tester.widget<Material>(
      find
          .descendant(of: find.byType(InkClip), matching: find.byType(Material))
          .first,
    );
    expect(material.shape, isA<RoundedRectangleBorder>());
    expect((material.shape! as RoundedRectangleBorder).borderRadius, radius);
  });
}
