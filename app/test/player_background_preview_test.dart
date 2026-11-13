// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 进入播放页时的背景铺底（对齐 SPlayer-Next `PlayerBackground.vue`）：
/// 水纹 / 流体尚未就绪时先显示模糊封面预览，不能露出纯底色（发黑）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/widgets/player/background/blurred_cover.dart';
import 'package:archoera_music/widgets/player/background/fluid_background.dart';
import 'package:archoera_music/widgets/player/background/player_background.dart';
import 'package:archoera_music/widgets/player/background/ripple_background.dart';

class _StubPrefs extends AppPrefsNotifier {
  _StubPrefs(this.value);

  AppPrefs value;

  @override
  AppPrefs build() => value;
}

Widget _wrap(AppPrefs prefs, Widget child) {
  final container = ProviderContainer(
    overrides: [appPrefsProvider.overrideWith(() => _StubPrefs(prefs))],
  );
  addTearDown(container.dispose);
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  testWidgets('流体背景未就绪：先铺模糊封面预览，不挂重效果', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AppPrefs(initialData: {playerBgTypeKey: 'fluid'}),
        const PlayerBackground(cover: '/tmp/cover.jpg', active: false),
      ),
    );

    expect(find.byType(BlurredCover), findsOneWidget);
    expect(find.byType(FluidBackground), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('流体背景就绪后：重效果挂载，预览仍在其下铺底', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AppPrefs(initialData: {playerBgTypeKey: 'fluid'}),
        const PlayerBackground(cover: '/tmp/cover.jpg', active: true),
      ),
    );
    // 重效果与歌词/频谱错峰：路由完成后延迟两帧再挂载。
    await tester.pump();
    await tester.pump();

    expect(find.byType(FluidBackground), findsOneWidget);
    // 预览层保留在流体之下，采样完成前不会露底色。
    expect(find.byType(BlurredCover), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('水纹背景未就绪：同样先铺模糊封面预览', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AppPrefs(initialData: {playerBgTypeKey: 'ripple'}),
        const PlayerBackground(cover: '/tmp/cover.jpg', active: false),
      ),
    );

    expect(find.byType(BlurredCover), findsOneWidget);
    expect(find.byType(RippleBackground), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('轻量样式不受 active 门控：纯色立即是最终态', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AppPrefs(initialData: {playerBgTypeKey: 'solid'}),
        const PlayerBackground(cover: '/tmp/cover.jpg', active: false),
      ),
    );

    expect(find.byType(BlurredCover), findsNothing);
    expect(find.byType(ColoredBox), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无封面时重效果直接回退主题渐变，不做无意义的预览', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AppPrefs(initialData: {playerBgTypeKey: 'fluid'}),
        const PlayerBackground(active: false),
      ),
    );

    expect(find.byType(BlurredCover), findsNothing);
    expect(find.byType(FluidBackground), findsNothing);
    expect(find.byType(DecoratedBox), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
