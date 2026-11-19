// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 内容区状态过渡（页面加载/空态/错误 ↔ 内容）与封面首帧淡入：
/// - [CrossFadeSwitcher] 做状态切换时两层共存，过渡结束只留目标态；
/// - 离场层不拦截点击、不参与语义；
/// - 过渡期间目标态内容更新后，下一次切换的离场层是**最新**内容（不是过期
///   快照）；
/// - 性能模式（`MediaQuery.disableAnimations`）同一帧直切；
/// - [coverFrameFade] 只在解码首帧到达时淡入，缓存同步命中不建动画层。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/widgets/common/cross_fade_switcher.dart';
import 'package:archoera_music/widgets/list/cover_image.dart';

/// 空状态 ↔ 内容 的极简宿主：`phase` 决定挂哪一层，`body` 模拟同相位的
/// 内容更新（例如列表数据刷新但仍是「内容」态）。
Widget _host({
  required ValueNotifier<String> phase,
  required ValueNotifier<String> body,
  bool disableAnimations = false,
  Key? childKey,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(
      body: Column(
        children: [
          Expanded(
            child: ValueListenableBuilder<String>(
              valueListenable: phase,
              builder: (context, phaseValue, _) => CrossFadeSwitcher(
                switchKey: phaseValue,
                child: switch (phaseValue) {
                  'loading' => const Center(child: Text('chunk-loading')),
                  _ => ValueListenableBuilder<String>(
                    valueListenable: body,
                    builder: (context, bodyValue, _) =>
                        Center(child: Text('body-$bodyValue', key: childKey)),
                  ),
                },
              ),
            ),
          ),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets('状态切换：过渡中两层共存，结束后只留目标态', (tester) async {
    final phase = ValueNotifier('loading');
    final body = ValueNotifier('v1');
    addTearDown(phase.dispose);
    addTearDown(body.dispose);

    await tester.pumpWidget(_host(phase: phase, body: body));
    expect(find.text('chunk-loading'), findsOneWidget);
    expect(find.text('body-v1'), findsNothing);

    phase.value = 'content';
    await tester.pump();
    // 交叉淡化：旧（加载）与新（内容）同帧存在。
    expect(find.text('chunk-loading'), findsOneWidget);
    expect(find.text('body-v1'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('chunk-loading'), findsNothing);
    expect(find.text('body-v1'), findsOneWidget);
  });

  testWidgets('离场层不吃点击（IgnorePointer）', (tester) async {
    final phase = ValueNotifier('loading');
    final body = ValueNotifier('v1');
    addTearDown(phase.dispose);
    addTearDown(body.dispose);
    var taps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(),
          child: ValueListenableBuilder<String>(
            valueListenable: phase,
            builder: (context, phaseValue, _) => CrossFadeSwitcher(
              switchKey: phaseValue,
              child: phaseValue == 'loading'
                  ? const Center(child: Text('chunk-loading'))
                  : Center(
                      child: GestureDetector(
                        key: const ValueKey('hit'),
                        onTap: () => taps++,
                        child: const SizedBox(
                          width: 120,
                          height: 120,
                          child: Text('body-v1'),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );

    phase.value = 'content';
    await tester.pump();
    // 离场层（加载态）居中且在上面，但它是 IgnorePointer，点击应命中目标层。
    await tester.tap(find.byKey(const ValueKey('hit')));
    expect(taps, 1);
    await tester.pumpAndSettle();
  });

  testWidgets('过渡期间内容更新：下一次切换离场层是最新内容', (tester) async {
    final phase = ValueNotifier('content');
    final body = ValueNotifier('v1');
    addTearDown(phase.dispose);
    addTearDown(body.dispose);

    await tester.pumpWidget(_host(phase: phase, body: body));
    expect(find.text('body-v1'), findsOneWidget);

    // 同一相位下内容刷新（列表数据更新），此时不触发交叉淡化。
    body.value = 'v2';
    await tester.pumpAndSettle();
    expect(find.text('body-v1'), findsNothing);
    expect(find.text('body-v2'), findsOneWidget);

    // 再切到加载态：离场层必须是最新的 v2，而不是首次切换时的快照。
    phase.value = 'loading';
    await tester.pump();
    expect(find.text('body-v2'), findsOneWidget);
    expect(find.text('body-v1'), findsNothing);

    await tester.pumpAndSettle();
    expect(find.text('body-v2'), findsNothing);
  });

  testWidgets('性能模式：同一帧直切，不留离场层', (tester) async {
    final phase = ValueNotifier('loading');
    final body = ValueNotifier('v1');
    addTearDown(phase.dispose);
    addTearDown(body.dispose);

    await tester.pumpWidget(
      _host(phase: phase, body: body, disableAnimations: true),
    );
    phase.value = 'content';
    await tester.pump();
    expect(find.text('chunk-loading'), findsNothing);
    expect(find.text('body-v1'), findsOneWidget);
  });

  testWidgets('过渡结束不重建内容：滚动位置保留', (tester) async {
    final phase = ValueNotifier('loading');
    addTearDown(phase.dispose);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(),
          child: Scaffold(
            body: ValueListenableBuilder<String>(
              valueListenable: phase,
              builder: (context, phaseValue, _) => CrossFadeSwitcher(
                switchKey: phaseValue,
                child: phaseValue == 'loading'
                    ? const Center(child: Text('chunk-loading'))
                    : ListView.builder(
                        controller: scroll,
                        itemCount: 200,
                        itemExtent: 40,
                        itemBuilder: (_, i) => Text('row-$i'),
                      ),
              ),
            ),
          ),
        ),
      ),
    );

    phase.value = 'content';
    await tester.pump();

    // 过渡进行中滚动列表：完成时要保留这一位置（旧实现会在离场层被移除
    // 的那一帧整棵子树重建，回到顶部）。
    scroll.jumpTo(600);
    await tester.pump();
    expect(scroll.offset, 600);

    await tester.pumpAndSettle();
    expect(find.text('chunk-loading'), findsNothing);
    expect(scroll.offset, 600);
  });

  group('coverFrameFade', () {
    Widget harness({
      required int? frame,
      required bool sync,
      bool disableAnimations = false,
    }) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Builder(
          builder: (context) => coverFrameFade(
            context,
            const SizedBox(width: 10, height: 10),
            frame,
            sync,
          ),
        ),
      ),
    );

    testWidgets('缓存同步命中：不包动画层，直接出图', (tester) async {
      await tester.pumpWidget(harness(frame: 0, sync: true));
      expect(find.byType(AnimatedOpacity), findsNothing);
    });

    testWidgets('首帧未到 → 透明；帧到达 → 不透明（180ms easeOut）', (tester) async {
      await tester.pumpWidget(harness(frame: null, sync: false));
      var opacity = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(opacity.opacity, 0);
      expect(opacity.duration, const Duration(milliseconds: 180));

      await tester.pumpWidget(harness(frame: 0, sync: false));
      opacity = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(opacity.opacity, 1);
      await tester.pumpAndSettle();
    });

    testWidgets('性能模式：不建动画层，直接出像素', (tester) async {
      await tester.pumpWidget(
        harness(frame: 0, sync: false, disableAnimations: true),
      );
      expect(find.byType(AnimatedOpacity), findsNothing);
    });
  });
}
