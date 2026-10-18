// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Vutron 经典布局冒烟测试：
/// - 左栏封面/信息/进度/控制/音量与右栏歌词能在 1200×720 内正常排版；
/// - 歌词复用共享配色：已唱/未唱颜色来自偏好；
/// - simple 引擎左对齐（含译文对齐），AMLL 引擎按偏好接入。
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
import 'package:archoera_music/widgets/player/lyrics_edge_fade.dart';
import 'package:archoera_music/widgets/player/lyrics_view.dart';
import 'package:archoera_music/widgets/player/lyrics_v7/lyrics_physics_wall.dart';
import 'package:archoera_music/widgets/player/playback_progress_slider.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

class _StubPrefs extends AppPrefsNotifier {
  _StubPrefs([this.data = const <String, dynamic>{}]);

  final Map<String, dynamic> data;

  @override
  AppPrefs build() => AppPrefs(initialData: data);
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
  LyricGroup(
    original: const LyricLine(timeMs: 0, text: '第一行歌词'),
    translation: '第一行翻译',
  ),
  LyricGroup(original: const LyricLine(timeMs: 2000, text: '第二行歌词')),
  LyricGroup(original: const LyricLine(timeMs: 4000, text: '第三行歌词')),
];

const int _played = 0xFFFF0000;
const int _unplayed = 0xFF00FF00;

Map<String, dynamic> _prefsData(String engine) => <String, dynamic>{
  // 验证 Vutron 预设复用统一取色逻辑：采用用户配置的已唱/未唱颜色。
  lyricEngineKey: engine,
  lyricPlayedColorKey: _played,
  lyricUnplayedColorKey: _unplayed,
  lyricFollowAccentKey: false,
  followCoverColorKey: false,
};

Future<void> _pumpVutron(
  WidgetTester tester, {
  required Map<String, dynamic> prefs,
}) async {
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
        appPrefsProvider.overrideWith(() => _StubPrefs(prefs)),
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
}

void main() {
  testWidgets('simple 引擎：左栏控制 + 左对齐歌词 + 共享配色', (tester) async {
    await _pumpVutron(tester, prefs: _prefsData('simple'));
    expect(find.byType(PlaybackProgressSlider), findsOneWidget);
    expect(find.byType(LyricsView), findsOneWidget);

    final view = tester.widget<LyricsView>(find.byType(LyricsView));
    expect(view.playedColor, const Color(_played));
    expect(view.unplayedColor, const Color(_unplayed));
    expect(view.textAlign, TextAlign.left);
    expect(view.inactiveScale, 0.95);
    // 渐隐由共享歌词区遮罩承担（SPlayer 的 10%/25% 非线性 mask）。
    expect(find.byType(LyricsEdgeFade), findsOneWidget);
    expect(view.currentFontSize, view.fontSize);

    // 播放键跟随主题色（与页面其它控制一致）。
    final scheme = Theme.of(tester.element(find.byType(Scaffold))).colorScheme;
    final playButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, EtaIcons.playCircle),
    );
    expect(playButton.color, scheme.primary);

    // 译文单行 textAlign 之外，行内 Column 的交叉轴也要左对齐。
    final translation = tester.widget<Text>(find.text('第一行翻译'));
    expect(translation.textAlign, TextAlign.left);
    final lineColumn = tester.widget<Column>(
      find.ancestor(of: find.text('第一行翻译'), matching: find.byType(Column)).last,
    );
    expect(lineColumn.crossAxisAlignment, CrossAxisAlignment.start);
  });

  testWidgets('AMLL 引擎：按偏好接入物理歌词墙并共享配色', (tester) async {
    await _pumpVutron(tester, prefs: _prefsData('amll'));
    final wall = tester.widget<AmllPhysicsWall>(find.byType(AmllPhysicsWall));
    expect(wall.playedColor, const Color(_played));
    expect(wall.unplayedColor, const Color(_unplayed));
    // 注册表声明的左对齐同样作用于 AMLL 物理墙。
    expect(wall.textAlign, TextAlign.left);
    expect(find.byType(LyricsEdgeFade), findsOneWidget);
    expect(find.byType(LyricsView), findsNothing);
  });
}
