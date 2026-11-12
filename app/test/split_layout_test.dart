// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 默认布局（split）封面自动居中回归：
/// 无歌词时封面应居中于主体，而不是依赖写死的位移比例
/// （旧实现 `Offset(11/18)` 只在 `coverLyricRatio ≈ 0.45` 时正确）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/pages/player/layouts/player_layout.dart';
import 'package:archoera_music/pages/player/layouts/split_layout.dart';
import 'package:archoera_music/services/playback/playback_notifier.dart';
import 'package:archoera_music/services/playback/playback_state.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/stores/lyrics_provider.dart';
import 'package:archoera_music/widgets/player/player_cover.dart';
import 'package:archoera_music/widgets/player/player_shared_elements.dart';

class _StubPrefs extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();
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

PlayerLayoutContext _ctx({
  required double ratio,
  required AnimationController pulse,
  required bool showLyrics,
  required bool hasLyrics,
}) => PlayerLayoutContext(
  current: null,
  coverKey: 'local:test',
  title: '测试曲目',
  subtitle: '测试歌手',
  playing: false,
  hasContent: true,
  hasLyrics: hasLyrics,
  showLyrics: showLyrics,
  contentMounted: true,
  transitionStyle: 'scale',
  coverLyricRatio: ratio,
  autoCenterCover: true,
  slideNext: true,
  coverPulse: pulse,
  beatStrength: 1,
  pageWidth: 1200,
  pageHeight: 720,
  fullscreenCoverWidth: 0,
  chromeOpacity: 1,
  buffering: false,
  hasSource: true,
  onDragChanged: (_) {},
  onSeekEnd: (_) {},
  l10n: lookupAppLocalizations(const Locale('zh')),
  onSeekLyric: null,
  dragMs: null,
  sharedKeys: PlayerSharedElementKeys('split-test'),
);

Future<void> _pump(
  WidgetTester tester, {
  required double ratio,
  required bool showLyrics,
  required bool hasLyrics,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 720);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final pulse = AnimationController(
    vsync: const TestVSync(),
    duration: const Duration(milliseconds: 100),
  );
  addTearDown(pulse.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appPrefsProvider.overrideWith(_StubPrefs.new),
        playbackProvider.overrideWith(_StubPlayback.new),
        currentLyricsProvider.overrideWith((ref) => const AsyncData([])),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 720,
            child: Builder(
              builder: (context) => const SplitPlayerLayout().buildBody(
                context,
                _ctx(
                  ratio: ratio,
                  pulse: pulse,
                  showLyrics: showLyrics,
                  hasLyrics: hasLyrics,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('无歌词时封面按比例正确居中（不写死位移）', (tester) async {
    // 0.6 的占比：旧实现会用 11/18 的固定位移，明显偏离主体中心。
    await _pump(tester, ratio: 0.6, showLyrics: false, hasLyrics: false);
    expect(tester.takeException(), isNull);
    final cover = tester.getRect(find.byType(PlayerCoverBlock));
    expect(cover.center.dx, closeTo(600, 1));
  });

  testWidgets('有歌词时封面留在左侧栏', (tester) async {
    await _pump(tester, ratio: 0.6, showLyrics: true, hasLyrics: true);
    expect(tester.takeException(), isNull);
    final cover = tester.getRect(find.byType(PlayerCoverBlock));
    // 左栏宽度 = 1200 * 0.6，封面在栏内居中。
    expect(cover.center.dx, closeTo(360, 1));
  });
}
