// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 回归：曲目列表弹窗不得在构建帧调用 loader。
///
/// 部分 loader 会同步修改 provider（如每日推荐 `dailyShelfProvider.ensure()`）；
/// 直接在 initState 调用会触发 Riverpod「Tried to modify a provider while the
/// widget tree was building」，并冒泡成弹窗「加载失败」。此处锁定「loader 在构建
/// 帧之后才执行」。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/stores/favorites_revision.dart';
import 'package:archoera_music/widgets/dialogs/track_list_dialog.dart';

void main() {
  testWidgets('TrackListDialog 延后调用 loader（不在构建期改 provider）', (
    WidgetTester tester,
  ) async {
    final container = ProviderContainer();
    var loaderCalled = false;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh', 'CN'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showKugouTracksDialog(
                    context,
                    title: 'T',
                    loadTracks: (ref) async {
                      loaderCalled = true;
                      // 构建帧内执行会触发 Riverpod 断言。
                      ref.read(favoritesRevisionProvider.notifier).bump();
                      return const <Track>[];
                    },
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump(); // 打开弹窗（触发 initState）这一帧
    expect(loaderCalled, isFalse, reason: 'loader 不得在构建帧执行');

    await tester.pump(const Duration(milliseconds: 1)); // 让出的一帧后执行
    await tester.pump(const Duration(milliseconds: 50));
    expect(loaderCalled, isTrue);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Tried to modify'), findsNothing);
    // 注：此处刻意不 dispose 容器——PlaybackNotifier 的 onDispose 回调在
    // `container.dispose()` 链中会调用 Ref 触发 Riverpod 断言（既有问题，
    // 与本用例无关）；应用内容器不销毁，故不影响运行。
  });
}
