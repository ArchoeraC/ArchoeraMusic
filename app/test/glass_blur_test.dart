// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// GlassBlur 性能模式降级回归测试。
///
/// 正常模式：保留 [BackdropFilter]（模糊为有意设计，逐字节不变）。
/// 性能模式：去掉模糊离屏 pass，仅剩 child；若提供 tint 则叠加半透明填充。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/widgets/common/glass_blur.dart';

/// 不读/写磁盘的偏好 Notifier，可指定性能模式。
class _TestPrefsNotifier extends AppPrefsNotifier {
  _TestPrefsNotifier({this.performanceMode = false});

  final bool performanceMode;

  @override
  AppPrefs build() =>
      AppPrefs(initialData: {performanceModeKey: performanceMode});
}

const _tint = Color(0x66123456);
const _childKey = ValueKey('glass-child');

Widget _wrap({
  required bool performanceMode,
  Color? tint,
  bool backdropIsBakedBlur = false,
}) {
  return ProviderScope(
    overrides: [
      appPrefsProvider.overrideWith(
        () => _TestPrefsNotifier(performanceMode: performanceMode),
      ),
    ],
    child: MaterialApp(
      home: Center(
        child: GlassBlur(
          sigma: 16,
          tint: tint,
          backdropIsBakedBlur: backdropIsBakedBlur,
          child: const SizedBox(key: _childKey, width: 40, height: 40),
        ),
      ),
    ),
  );
}

Finder _tintBox() => find.descendant(
  of: find.byType(GlassBlur),
  matching: find.byType(ColoredBox),
);

void main() {
  testWidgets('正常模式：存在 BackdropFilter，child 保留', (tester) async {
    await tester.pumpWidget(_wrap(performanceMode: false));

    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byKey(_childKey), findsOneWidget);
  });

  testWidgets('正常模式：tint 不参与输出（不叠加填充层）', (tester) async {
    await tester.pumpWidget(_wrap(performanceMode: false, tint: _tint));

    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byKey(_childKey), findsOneWidget);
    expect(_tintBox(), findsNothing);
  });

  testWidgets('性能模式：无 BackdropFilter，child 保留', (tester) async {
    await tester.pumpWidget(_wrap(performanceMode: true));

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byKey(_childKey), findsOneWidget);
    expect(_tintBox(), findsNothing);
  });

  testWidgets('性能模式：提供 tint 时叠加半透明填充', (tester) async {
    await tester.pumpWidget(_wrap(performanceMode: true, tint: _tint));

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byKey(_childKey), findsOneWidget);
    expect(_tintBox(), findsOneWidget);
    expect(tester.widget<ColoredBox>(_tintBox()).color, _tint);
  });

  testWidgets('共享模糊输入：正常模式下也不创建 BackdropFilter', (tester) async {
    // 背后只有预烘焙模糊背景（停靠播放条）：复用背景那次模糊，
    // 不再付每帧整条离屏 pass。
    await tester.pumpWidget(_wrap(performanceMode: false, backdropIsBakedBlur: true));

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byKey(_childKey), findsOneWidget);
    // tint 不受影响：共享输入不是降级，正常模式不叠填充层。
    expect(_tintBox(), findsNothing);
  });

  testWidgets('共享模糊输入：性能模式下行为与普通降级一致', (tester) async {
    await tester.pumpWidget(
      _wrap(performanceMode: true, tint: _tint, backdropIsBakedBlur: true),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byKey(_childKey), findsOneWidget);
    expect(_tintBox(), findsOneWidget);
    expect(tester.widget<ColoredBox>(_tintBox()).color, _tint);
  });
}
