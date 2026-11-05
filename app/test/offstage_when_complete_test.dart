// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `OffstageWhenComplete` 回归测试：
/// - 未完成时正常显示；
/// - 完成（value ≥ 阈值）后停绘，但**保留子树状态**（返回时无重建闪烁）；
/// - 回退（value < 阈值）后重新显示，状态连续。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/widgets/common/offstage_when_complete.dart';

void main() {
  testWidgets('完成阈值前后切换停绘，子树状态保留', (tester) async {
    final controller = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 300),
    );

    var built = 0;
    Widget host() => Directionality(
      textDirection: TextDirection.ltr,
      child: OffstageWhenComplete(
        animation: controller,
        child: Builder(
          builder: (_) {
            built += 1;
            return const SizedBox(width: 100, height: 100);
          },
        ),
      ),
    );

    await tester.pumpWidget(host());
    Offstage offstageOf() => tester.widget<Offstage>(find.byType(Offstage));
    expect(offstageOf().offstage, isFalse);

    // 动画中途：仍在绘制。
    controller.value = 0.5;
    await tester.pump();
    expect(offstageOf().offstage, isFalse);

    // 完成：停绘，但 child 未重建（element 保留）。
    final buildsBefore = built;
    controller.value = 1.0;
    await tester.pump();
    expect(offstageOf().offstage, isTrue);
    expect(built, buildsBefore, reason: '停绘不应触发 child 重建（保留状态）');

    // 回退：重新显示，仍是同一份子树。
    controller.value = 0.2;
    await tester.pump();
    expect(offstageOf().offstage, isFalse);
    expect(built, buildsBefore, reason: '恢复显示不应重建 child');

    controller.dispose();
  });

  testWidgets('阈值边界：0.999 视为完成，0.998 仍绘制', (tester) async {
    final controller = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 300),
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: OffstageWhenComplete(
          animation: controller,
          child: const SizedBox(width: 10, height: 10),
        ),
      ),
    );
    Offstage offstageOf() => tester.widget<Offstage>(find.byType(Offstage));

    controller.value = 0.998;
    await tester.pump();
    expect(offstageOf().offstage, isFalse);

    controller.value = 0.999;
    await tester.pump();
    expect(offstageOf().offstage, isTrue);

    controller.dispose();
  });
}
