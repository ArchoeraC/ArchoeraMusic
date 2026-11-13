// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// [shell_page_state] 回归测试：平台 / Tab 选择存于应用级 provider，因此在
/// `ShellExpandTransition` 卸载/重挂载壳内容（全屏播放页展开后）时得以保留，
/// 不会回到默认值。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:archoera_music/app/shell_expand_transition.dart';
import 'package:archoera_music/stores/shell_page_state.dart';

/// 模拟「页面」：把平台与 Tab 选择存在 provider，`State` 重建时从中恢复。
class _PlatformPicker extends ConsumerStatefulWidget {
  const _PlatformPicker();

  @override
  ConsumerState<_PlatformPicker> createState() => _PlatformPickerState();
}

class _PlatformPickerState extends ConsumerState<_PlatformPicker> {
  late String _platform;
  late int _tab;

  @override
  void initState() {
    super.initState();
    _platform = ref.read(searchPlatformProvider) ?? 'netease';
    _tab = ref.read(searchTabIndexProvider) ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        ref.read(searchPlatformProvider.notifier).set('kugou');
        ref.read(searchTabIndexProvider.notifier).set(2);
        setState(() {
          _platform = 'kugou';
          _tab = 2;
        });
      },
      child: Text('platform:$_platform tab:$_tab'),
    );
  }
}

Widget _host(Animation<double> animation) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: ShellExpandTransition(
          animation: animation,
          placeholder: const Text('placeholder'),
          child: const _PlatformPicker(),
        ),
      ),
    ),
  );
}

void main() {
  group('ShellPageSelection', () {
    test('默认未选择；set 写值、相同值去重', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(searchPlatformProvider), isNull);
      expect(container.read(searchTabIndexProvider), isNull);
      expect(container.read(favoritesKugouTabProvider), isNull);

      container.read(searchPlatformProvider.notifier).set('kugou');
      expect(container.read(searchPlatformProvider), 'kugou');

      var notifications = 0;
      container.listen(searchPlatformProvider, (_, _) => notifications++);
      container.read(searchPlatformProvider.notifier).set('kugou');
      expect(notifications, 0);
      container.read(searchPlatformProvider.notifier).set('netease');
      expect(container.read(searchPlatformProvider), 'netease');
      expect(notifications, 1);
    });
  });

  group('壳内容卸载/重挂载', () {
    testWidgets('保留平台与 Tab 选择（不回到默认 NT / 首个 Tab）', (tester) async {
      final c = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(milliseconds: 100),
      );
      addTearDown(c.dispose);

      await tester.pumpWidget(_host(c));
      expect(find.text('platform:netease tab:0'), findsOneWidget);

      await tester.tap(find.text('platform:netease tab:0'));
      await tester.pump();
      expect(find.text('platform:kugou tab:2'), findsOneWidget);

      // 展开 → 壳内容从树上卸载。
      c.value = 1;
      await tester.pumpAndSettle();
      expect(find.text('placeholder'), findsOneWidget);
      expect(find.text('platform:kugou tab:2'), findsNothing);

      // 收起 → 壳内容重新挂载（全新 `State`），选择应被恢复。
      c.reverse();
      await tester.pumpAndSettle();
      expect(find.text('platform:kugou tab:2'), findsOneWidget);
    });
  });
}
