// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Vutron 经典布局冒烟测试：
/// - 左栏封面/信息/进度/控制/音量与右栏歌词能在 1200×720 内正常排版；
/// - 控制不再依赖页面共享底栏（复用 Vutron 自己的控制条）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/pages/player/layouts/player_layout.dart';
import 'package:archoera_music/pages/player/layouts/vutron_layout.dart';
import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/services/playback/playback_notifier.dart';
import 'package:archoera_music/services/playback/playback_state.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/stores/lyrics_provider.dart';
import 'package:archoera_music/widgets/player/lyrics_view.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/lyrics_physics_wall.dart';
import 'package:archoera_music/widgets/player/playback_progress_slider.dart';

class _StubPrefs extends AppPrefsNotifier {
  _StubPrefs([this.data = const <String, dynamic>{}]);

  final Map<String, dynamic> data;

  @override
  AppPrefs build() => AppPrefs(initialData: data);
}

class _StubPlayback extends PlaybackNotifier {
  @override
  PlaybackState build() => const PlaybackState(
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

void main() {
  testWidgets('经典布局：左栏控制 + 右栏歌词排版无异常', (tester) async {
    final pulse = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 100),
    );
    addTearDown(pulse.dispose);
    final ctx = PlayerLayoutContext(
      current: null,
      coverKey: 'local:test',
      title: '测试曲目',
      subtitle: '测试歌手',
      playing: false,
      hasContent: true,
      hasLyrics: true,
      showLyrics: true,
      contentMounted: true,
      transitionStyle: 'scale',
      coverLyricRatio: 0.45,
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
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appPrefsProvider.overrideWith(
            () => _StubPrefs(const <String, dynamic>{
              // 验证 Vutron 预设复用统一取色逻辑：即使偏好引擎是 AMLL，
              // 也走 simple 列表并采用用户配置的已唱/未唱颜色。
              lyricEngineKey: 'amll',
              lyricPlayedColorKey: 0xFFFF0000,
              lyricUnplayedColorKey: 0xFF00FF00,
              lyricFollowAccentKey: false,
              followCoverColorKey: false,
            }),
          ),
          playbackProvider.overrideWith(_StubPlayback.new),
          currentLyricsProvider.overrideWith((ref) async => _groups),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              height: 720,
              child: Builder(
                builder: (context) =>
                    const VutronPlayerLayout().buildBody(context, ctx),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);
    expect(find.byType(PlaybackProgressSlider), findsOneWidget);
    expect(find.byType(LyricsView), findsOneWidget);

    // 复用现有引擎的配色：已唱/未唱颜色来自偏好，而非布局里写死的颜色。
    final view = tester.widget<LyricsView>(find.byType(LyricsView));
    expect(view.playedColor, const Color(0xFFFF0000));
    expect(view.unplayedColor, const Color(0xFF00FF00));
    expect(view.textAlign, TextAlign.left);
    expect(view.fadeEdges, isTrue);
    expect(view.inactiveScale, 0.95);
    expect(view.currentFontSize, view.fontSize);
    expect(
      find.descendant(
        of: find.byType(LyricsView),
        matching: find.byType(AmllPhysicsWall),
      ),
      findsNothing,
      reason: 'Vutron 预设应强制 simple 列表，而不是 AMLL 物理墙',
    );
  });
}
