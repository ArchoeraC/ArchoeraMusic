// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放页顶栏布局切换回归：
/// - 菜单选项来自 `playerLayouts` 注册表，选中写回 `player.coverLayout`；
/// - 新布局的真实共享元素（封面 / 曲目信息 / 歌词）从旧布局矩形变换到
///   自身矩形，不是整页滑动，也不是旧布局截图；
/// - 目标矩形来自布局实际的 `RenderBox`，在非默认窗口尺寸下也成立；
/// - 动画结束后旧布局卸载，新布局元素落在自身位置。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';
import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/pages/player_page.dart';
import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/services/playback/playback_notifier.dart';
import 'package:archoera_music/services/playback/playback_state.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/stores/lyrics_provider.dart';
import 'package:archoera_music/widgets/player/player_cover.dart';
import 'package:archoera_music/widgets/player/player_lyrics_block.dart';

class _StubPrefs extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();

  /// 测试里改布局只更新内存，避免把用户真实的 prefs.json 写坏。
  @override
  void setCoverLayout({
    String? layout,
    double? ratio,
    bool? autoCenter,
    bool? followCoverColor,
  }) {
    state = state.copyWithCoverLayout(
      layout: layout,
      ratio: ratio,
      autoCenter: autoCenter,
      followCoverColor: followCoverColor,
    );
  }
}

class _StubPlayback extends PlaybackNotifier {
  @override
  PlaybackState build() => const PlaybackState(
    source: 'test-source',
    title: '测试曲目',
    subtitle: '测试歌手',
    duration: Duration(minutes: 4),
  );
}

final List<LyricGroup> _groups = <LyricGroup>[
  LyricGroup(original: const LyricLine(timeMs: 0, text: '第一行歌词')),
  LyricGroup(original: const LyricLine(timeMs: 2000, text: '第二行歌词')),
  LyricGroup(original: const LyricLine(timeMs: 4000, text: '第三行歌词')),
];

ProviderContainer _container({bool withLyrics = false}) => ProviderContainer(
  overrides: [
    appPrefsProvider.overrideWith(_StubPrefs.new),
    playbackProvider.overrideWith(_StubPlayback.new),
    currentLyricsProvider.overrideWith(
      (ref) => withLyrics ? AsyncData(_groups) : const AsyncData([]),
    ),
  ],
);

Future<void> _pumpPage(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const PlayerPage(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
}

Future<void> _selectLayout(WidgetTester tester, String label) async {
  await tester.tap(find.byIcon(EtaIcons.columnsOutline));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, label));
  await tester.pump();
}

void main() {
  testWidgets('新布局共享元素从旧矩形移动到自身矩形', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = _container();
    addTearDown(container.dispose);
    await _pumpPage(tester, container);
    expect(tester.takeException(), isNull);
    expect(find.byType(PlayerCoverBlock), findsOneWidget);
    expect(find.byType(PlayerFullscreenCover), findsNothing);

    await _selectLayout(tester, 'Fullscreen cover');
    expect(container.read(appPrefsProvider).coverLayout, 'fullscreen');
    // 切换首帧：旧布局仍在，新布局已挂载（共享元素先隐藏等待测量）。
    expect(find.byType(PlayerCoverBlock), findsOneWidget);
    expect(find.byType(PlayerFullscreenCover), findsOneWidget);

    // 控制器在首帧后启动：先推进一次建立时间基准，此时新封面仍叠在旧位置。
    await tester.pump();
    final coverStart = tester.getRect(find.byType(PlayerFullscreenCover));
    final infoStart = tester.getRect(find.text('测试歌手').last);

    // 中段：新封面在变大、信息在离开旧信息位。
    await tester.pump(const Duration(milliseconds: 220));
    final coverMid = tester.getRect(find.byType(PlayerFullscreenCover));
    final infoMid = tester.getRect(find.text('测试歌手').last);
    expect(
      coverMid.width,
      greaterThan(coverStart.width + 40),
      reason: '新封面应从旧位置向整幅封面位置放大',
    );
    expect(
      (infoMid.center.dx - infoStart.center.dx).abs(),
      greaterThan(40),
      reason: '曲目信息应移动到新布局的信息位',
    );

    // 结束：旧布局卸载，新布局元素落在自身位置。
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(PlayerCoverBlock), findsNothing);
    final coverEnd = tester.getRect(find.byType(PlayerFullscreenCover));
    expect(coverEnd.width, greaterThan(coverMid.width));
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌词从旧矩形落到新布局实际矩形（非硬编码）', (tester) async {
    // 非默认窗口尺寸：目标位置必须由新布局实时测量，而不是写死坐标。
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1366, 768);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final container = _container(withLyrics: true);
    addTearDown(container.dispose);
    await _pumpPage(tester, container);
    expect(tester.takeException(), isNull);
    expect(find.byType(PlayerLyricsBlock), findsOneWidget);
    final start = tester.getRect(find.byType(PlayerLyricsBlock));

    await _selectLayout(tester, 'Vutron classic');
    // 首帧建立时间基准：新布局的歌词此时应还在旧矩形附近。
    await tester.pump();
    final newLyrics = find.byType(PlayerLyricsBlock).last;
    final movedFrom = tester.getRect(newLyrics);
    expect(movedFrom.left, closeTo(start.left, 2));
    expect(movedFrom.top, closeTo(start.top, 2));
    expect(movedFrom.right, closeTo(start.right, 2));
    expect(movedFrom.bottom, closeTo(start.bottom, 2));

    // 接近终点：新布局歌词应已到自身矩形。
    await tester.pump(const Duration(milliseconds: 470));
    final nearEnd = tester.getRect(newLyrics);
    expect(
      (nearEnd.left - start.left).abs(),
      greaterThan(20),
      reason: '歌词应确实从旧布局位置移动',
    );

    await tester.pump(const Duration(milliseconds: 100));
    final live = tester.getRect(find.byType(PlayerLyricsBlock));
    // 动画终点与新布局真实歌词矩形一致（允许亚像素/动画末帧误差）。
    expect(live.left, closeTo(nearEnd.left, 2));
    expect(live.top, closeTo(nearEnd.top, 2));
    expect(live.right, closeTo(nearEnd.right, 2));
    expect(live.bottom, closeTo(nearEnd.bottom, 2));
    expect(tester.takeException(), isNull);
  });
}
