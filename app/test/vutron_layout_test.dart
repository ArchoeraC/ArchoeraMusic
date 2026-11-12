// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Vutron 经典布局冒烟测试：
/// - 左栏封面/信息/进度/控制/音量与右栏歌词能在 1200×720 内正常排版；
/// - 歌词复用共享配色：已唱/未唱颜色来自偏好；
/// - simple 引擎左对齐（含译文对齐），AMLL 引擎按偏好接入。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
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
import 'package:archoera_music/widgets/player/playback_slider.dart';
import 'package:archoera_music/widgets/player/player_lyrics_block.dart';
import 'package:archoera_music/widgets/player/player_shared_elements.dart';
import 'package:archoera_music/widgets/player/play_pause_button.dart';
import 'package:archoera_music/widgets/player/spectrum_view.dart';

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

PlayerLayoutContext _ctx({
  required bool showLyrics,
  required AnimationController pulse,
  bool autoCenterCover = true,
}) => PlayerLayoutContext(
  current: null,
  coverKey: 'local:test',
  title: '测试曲目',
  subtitle: '测试歌手',
  playing: false,
  hasContent: true,
  hasLyrics: true,
  showLyrics: showLyrics,
  contentMounted: true,
  transitionStyle: 'scale',
  coverLyricRatio: 0.45,
  autoCenterCover: autoCenterCover,
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
  sharedKeys: PlayerSharedElementKeys('test'),
);

Future<void> _pumpVutron(
  WidgetTester tester, {
  required Map<String, dynamic> prefs,
  bool showLyrics = true,
  bool autoCenterCover = true,
  ValueNotifier<bool>? showLyricsListenable,
}) async {
  final pulse = AnimationController(
    vsync: const TestVSync(),
    duration: const Duration(milliseconds: 100),
  );
  addTearDown(pulse.dispose);
  final ctx = _ctx(
    showLyrics: showLyrics,
    pulse: pulse,
    autoCenterCover: autoCenterCover,
  );
  final body = showLyricsListenable == null
      ? Builder(
          builder: (context) =>
              const VutronPlayerLayout().buildBody(context, ctx),
        )
      : ValueListenableBuilder<bool>(
          valueListenable: showLyricsListenable,
          builder: (context, value, _) => const VutronPlayerLayout().buildBody(
            context,
            _ctx(
              showLyrics: value,
              pulse: pulse,
              autoCenterCover: autoCenterCover,
            ),
          ),
        );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appPrefsProvider.overrideWith(() => _StubPrefs(prefs)),
        playbackProvider.overrideWith(_StubPlayback.new),
        currentLyricsProvider.overrideWith((ref) => AsyncData(_groups)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SizedBox(width: 1200, height: 720, child: body)),
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

    // 播放键：椭圆胶囊（横向长于纵向），实心底色跟随主题色。
    final scheme = Theme.of(tester.element(find.byType(Scaffold))).colorScheme;
    final playButton = tester.widget<PlayPauseButton>(
      find.byType(PlayPauseButton),
    );
    expect(playButton.playing, isFalse);
    final pill = tester.getSize(find.byType(PlayPauseButton));
    expect(pill.width, greaterThan(pill.height));
    final fill =
        (tester
                    .widget<AnimatedContainer>(
                      find.descendant(
                        of: find.byType(PlayPauseButton),
                        matching: find.byType(AnimatedContainer),
                      ),
                    )
                    .decoration!
                as BoxDecoration)
            .color;
    expect(fill, scheme.primary);

    // 译文单行 textAlign 之外，行内 Column 的交叉轴也要左对齐。
    // 取**最近一层** Column（ancestor 按由近及远排列）：布局外层（如 vutron
    // 底部的频谱容器）也可能引入 Column，用 .last 会误取到外层容器。
    final translation = tester.widget<Text>(find.text('第一行翻译'));
    expect(translation.textAlign, TextAlign.left);
    final lineColumn = tester.widget<Column>(
      find
          .ancestor(of: find.text('第一行翻译'), matching: find.byType(Column))
          .first,
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
    // 上下渐隐默认走逐行 alpha（零离屏层）→ 墙体自身承担，不再套 ShaderMask。
    expect(wall.edgeFade, isTrue);
    expect(find.byType(LyricsEdgeFade), findsNothing);
    expect(find.byType(LyricsView), findsNothing);
  });

  testWidgets('关闭歌词：经典布局只保留居中的封面/控制区', (tester) async {
    await _pumpVutron(tester, prefs: _prefsData('simple'), showLyrics: false);
    expect(find.byType(LyricsView), findsNothing);
    expect(find.byType(AmllPhysicsWall), findsNothing);
    expect(find.byType(PlaybackProgressSlider), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('开关歌词：左栏平移居中，歌词槽滑出而非整棵替换', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final showLyrics = ValueNotifier(true);
    addTearDown(showLyrics.dispose);
    await _pumpVutron(
      tester,
      prefs: _prefsData('simple'),
      showLyricsListenable: showLyrics,
    );
    final before = tester.getCenter(find.byType(PlayPauseButton)).dx;
    expect(before, lessThan(400), reason: '有歌词时左栏在左半区');

    showLyrics.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    final mid = tester.getCenter(find.byType(PlayPauseButton)).dx;
    expect(mid, greaterThan(before + 20), reason: '左栏应在平移中');
    expect(mid, lessThan(580), reason: '不应瞬间跳到页面中心');
    expect(
      find.byType(PlayerLyricsBlock),
      findsOneWidget,
      reason: '歌词槽仍在滑出，不能整棵替换',
    );

    await tester.pump(const Duration(milliseconds: 800));
    final after = tester.getCenter(find.byType(PlayPauseButton)).dx;
    expect(after, greaterThan(mid + 20));
    expect(after, closeTo(600, 24), reason: '最终应在页面中心');
    expect(find.byType(PlayerLyricsBlock), findsNothing);
  });

  testWidgets('底部细频谱：开启时渲染', (tester) async {
    await _pumpVutron(
      tester,
      prefs: {..._prefsData('simple'), enableSpectrumKey: true},
    );
    expect(find.byType(SpectrumView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('底部细频谱：关闭时零高度（不渲染、不占位）', (tester) async {
    await _pumpVutron(
      tester,
      prefs: {..._prefsData('simple'), enableSpectrumKey: false},
    );
    expect(find.byType(SpectrumView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('进度条与音量条：共用滑动条且左右边缘对齐', (tester) async {
    await _pumpVutron(tester, prefs: _prefsData('simple'));
    final sliders = find.byType(PlaybackSlider);
    expect(sliders, findsNWidgets(2), reason: '进度条与音量条都用 PlaybackSlider');

    final progress = tester.getRect(sliders.at(0));
    final volume = tester.getRect(sliders.at(1));
    // 同一列里两条轨道必须共用栅格（PlayerSliderRow），左右边缘不漂移。
    expect(volume.left, closeTo(progress.left, 0.5));
    expect(volume.right, closeTo(progress.right, 0.5));

    // 进度条与音量条声明同一轨道粗细（4px）；不再常显高亮圆点。
    expect(tester.widget<PlaybackSlider>(sliders.at(0)).trackHeight, 4);
    expect(tester.widget<PlaybackSlider>(sliders.at(1)).trackHeight, 4);
    // 纯条声明：静止、悬停、拖动都不画圆点。
    expect(tester.widget<PlaybackSlider>(sliders.at(0)).showThumb, isFalse);
    expect(tester.widget<PlaybackSlider>(sliders.at(1)).showThumb, isFalse);

    // 音量条不是进度：不显示时间/歌词气泡，也不参与愚人节反向映射。
    final volumeSlider = tester.widget<PlaybackSlider>(sliders.at(1));
    expect(volumeSlider.showTooltip, isFalse);
    expect(volumeSlider.allowPrank, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('悬停进度条也不展开滑块圆点（纯条）', (tester) async {
    await _pumpVutron(tester, prefs: _prefsData('simple'));
    final progress = find.byType(PlaybackProgressSlider);
    final center = tester.getCenter(progress);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: center);
    await tester.pump();
    await mouse.moveTo(center);
    await tester.pumpAndSettle();

    // showThumb=false → 不会切换成 Material Slider，自然也没有悬停 thumb。
    expect(find.byType(Slider), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
