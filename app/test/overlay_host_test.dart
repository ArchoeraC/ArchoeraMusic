// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:archoera_music/widgets/common/overlay_host.dart';

/// 回归（2026-10-14 实录）：`MaterialApp.builder` 的 `child` 是 Navigator，Flutter 的
/// `Overlay` 在 Navigator **内部**；挂在 builder 里、**位于 Navigator 之上**的门
/// （`VaultUnlockGate` 等）内的 `EditableText` 聚焦/选择/粘贴时 `Overlay.of(context)`
/// 返回 null → `result!` 抛 `Null check operator used on a null value`
/// （现象：解锁门里**粘贴恢复码无效**、平台报 "Failed to update editing state"）。
///
/// [OverlayHost] 在门内补一个 Overlay 祖先修掉它。
void main() {
  testWidgets('门（Navigator 之上）：不加 OverlayHost 时门内**没有** Overlay 祖先',
      (tester) async {
    late BuildContext inner;
    await tester.pumpWidget(MaterialApp(
      // builder 的 child 是 Navigator；此处与门位置一致（Navigator 之外）。
      builder: (context, child) => Builder(builder: (c) {
        inner = c;
        return const SizedBox.shrink();
      }),
      home: const SizedBox.shrink(),
    ));
    expect(Overlay.maybeOf(inner), isNull,
        reason: '门在 Navigator 之外 ⇒ 无 Overlay 祖先（这正是原 bug 的根因）');
  });

  testWidgets('OverlayHost：门内补上 Overlay 祖先（文本选择/粘贴的前提）', (tester) async {
    late BuildContext inner;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => OverlayHost(
        child: Builder(builder: (c) {
          inner = c;
          return const SizedBox.shrink();
        }),
      ),
      home: const SizedBox.shrink(),
    ));
    expect(Overlay.maybeOf(inner), isNotNull,
        reason: 'OverlayHost 必须为门内提供 Overlay 祖先');
  });

  testWidgets('OverlayHost：门内 TextField 聚焦 + 输入（粘贴同路径）不抛异常', (tester) async {
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => OverlayHost(
        child: Scaffold(body: TextField(autofocus: true)),
      ),
      home: const SizedBox.shrink(),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'recovery-code-1234-ABCD');
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '聚焦/输入不应抛 Overlay 空指针');
    expect(find.text('recovery-code-1234-ABCD'), findsOneWidget);
  });
}
