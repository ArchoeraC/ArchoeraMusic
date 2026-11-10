// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 整幅封面布局回归：歌词不可关闭 + 几何对齐 SPlayer `FullCoverLayout`。
/// - 顶栏歌词开关在该布局下禁用（`lyricsToggleable == false`）；
/// - 无歌词时右栏显示「暂无歌词」占位（`showLyrics` 偏好不影响该布局）；
/// - 文字/歌词列从整页 50% 处开始（封面渐隐尾部延伸到其下方）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/pages/player/layouts/player_layout.dart';
import 'package:archoera_music/pages/player/layouts/poster_layout.dart';
import 'package:archoera_music/pages/player/layouts/split_layout.dart';
import 'package:archoera_music/pages/player/layouts/vutron_layout.dart';
import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/services/playback/playback_notifier.dart';
import 'package:archoera_music/services/playback/playback_state.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/stores/lyrics_provider.dart';
import 'package:archoera_music/widgets/player/player_lyrics_block.dart';
import 'package:archoera_music/widgets/player/player_shared_elements.dart';

PlayerLayoutContext _ctx({
  required bool hasLyrics,
  bool showLyrics = false,
  required AnimationController pulse,
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
  coverLyricRatio: 0.45,
  autoCenterCover: true,
  slideNext: true,
  coverPulse: pulse,
  beatStrength: 1,
  pageWidth: 1200,
  pageHeight: 720,
  fullscreenCoverWidth: 720,
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

Future<void> _pump(
  WidgetTester tester, {
  required bool hasLyrics,
  bool showLyrics = false,
}) async {
  final pulse = AnimationController(
    vsync: const TestVSync(),
    duration: const Duration(milliseconds: 100),
  );
  addTearDown(pulse.dispose);
  final ctx = _ctx(hasLyrics: hasLyrics, showLyrics: showLyrics, pulse: pulse);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SizedBox(
          width: 1200,
          height: 720,
          child: Builder(
            builder: (context) =>
                const PosterPlayerLayout().buildBody(context, ctx),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);
}

/// 歌词区所需的 Riverpod 桩（空态与常驻路径共用）。
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

final List<LyricGroup> _groups = <LyricGroup>[
  LyricGroup(original: const LyricLine(timeMs: 0, text: '第一行歌词')),
];

void main() {
  test('全屏封面布局：歌词开关不可用（歌词常驻，无关闭入口）', () {
    expect(const PosterPlayerLayout().lyricsToggleable, isFalse);
    expect(const SplitPlayerLayout().lyricsToggleable, isTrue);
    expect(const VutronPlayerLayout().lyricsToggleable, isTrue);
  });

  testWidgets('关闭歌词偏好也照常渲染右栏（该布局无歌词开关）', (tester) async {
    // hasLyrics=false 时右栏给占位提示（不依赖歌词引擎，可直接泵）；
    // hasLyrics=true 的常驻路径由 PlayerLyricsSlot 的 enabled 保证。
    await _pump(tester, hasLyrics: false, showLyrics: false);
    expect(find.text('暂无歌词'), findsOneWidget);
    expect(find.text('测试曲目'), findsOneWidget);
  });

  testWidgets('曲目信息从整页 50% 处开始（渐隐尾部延伸到其下方）', (tester) async {
    await _pump(tester, hasLyrics: false);
    // coverInset = 1200 * 0.5 - 32 = 568；信息块左内边距 4。
    final left = tester.getTopLeft(find.text('测试曲目')).dx;
    expect(left, greaterThan(560));
    expect(left, lessThan(590));
    // 信息保持在顶部（无歌词时不再垂直居中）。
    final center = tester.getCenter(find.text('测试曲目'));
    expect(center.dy, lessThan(180));
  });

  testWidgets('歌词槽滑出期间不会叠加第二处「暂无歌词」', (tester) async {
    // 从「有歌词」切到「无歌词」时歌词槽会在 ~480ms 内下滑卸载；滑出期间
    // 歌词块仍在树上，若它自己再画一份空态，就会和布局层居中占位同时出现
    // 两条「暂无歌词」（其中一条随槽滑动）。
    var hasLyrics = true;
    late StateSetter rebuild;
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
          currentLyricsProvider.overrideWith((ref) => AsyncData(_groups)),
        ],
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              height: 720,
              child: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return const PosterPlayerLayout().buildBody(
                    context,
                    _ctx(hasLyrics: hasLyrics, showLyrics: true, pulse: pulse),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(PlayerLyricsBlock), findsOneWidget);
    expect(find.text('暂无歌词'), findsNothing);

    rebuild(() => hasLyrics = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // 槽仍在滑出（歌词块尚未卸载），空态只能有布局层那一处。
    expect(find.byType(PlayerLyricsBlock), findsOneWidget);
    expect(find.text('暂无歌词'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(PlayerLyricsBlock), findsNothing);
    expect(find.text('暂无歌词'), findsOneWidget);
  });
}
