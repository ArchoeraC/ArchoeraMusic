// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 进度条悬停/拖动提示：时间旁一并显示该位置的歌词行（时间显示的歌词定位）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/lyrics/lyric_line.dart';
import 'package:archoera_music/services/playback/playback_notifier.dart';
import 'package:archoera_music/services/playback/playback_state.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/stores/lyrics_provider.dart';
import 'package:archoera_music/theme/app_theme.dart';
import 'package:archoera_music/widgets/layout/player_bar.dart';
import 'package:archoera_music/widgets/player/playback_progress_slider.dart';
import 'package:archoera_music/widgets/player/playback_slider.dart';

/// 固定播放态：20s 时长、位于开头（不启动引擎）。
class _FakePlayback extends PlaybackNotifier {
  @override
  PlaybackState build() => const PlaybackState(
    source: 'test',
    title: 'T',
    position: Duration.zero,
    duration: Duration(seconds: 20),
  );
}

class _Prefs extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();
}

const _groups = <LyricGroup>[
  LyricGroup(original: LyricLine(timeMs: 0, text: '第一行')),
  LyricGroup(original: LyricLine(timeMs: 2000, text: '第二行')),
];

Future<void> _pump(WidgetTester tester, {required bool showTimes}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appPrefsProvider.overrideWith(_Prefs.new),
        playbackProvider.overrideWith(_FakePlayback.new),
        currentLyricsProvider.overrideWith((ref) async => _groups),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              height: 60,
              child: PlaybackProgressSlider(
                showTimes: showTimes,
                onDragChanged: (_) {},
                onSeekEnd: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('悬停进度条：时间提示旁显示对应歌词行', (tester) async {
    await _pump(tester, showTimes: false);
    // 未悬停：不渲染提示（时间与歌词都不显示）。
    expect(find.text('第二行'), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(
      location: tester.getCenter(find.byType(PlaybackProgressSlider)),
    );
    await tester.pump();
    await mouse.moveTo(
      tester.getCenter(find.byType(PlaybackProgressSlider)),
    );
    await tester.pumpAndSettle();

    // 指针落在轨道中部（≈10s）→ 对应 2s 起的「第二行」。
    expect(find.text('第二行'), findsOneWidget);
    expect(find.text('第一行'), findsNothing);

    await mouse.removePointer();
  });

  testWidgets('悬停时间气泡跟随指针、不铺满进度条', (tester) async {
    await _pump(tester, showTimes: false);
    final slider = tester.getRect(find.byType(PlaybackSlider));
    final target = Offset(
      slider.left + slider.width * 0.6,
      slider.center.dy,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: target);
    await tester.pump();
    await mouse.moveTo(target);
    await tester.pumpAndSettle();

    // 回归：气泡曾被父约束拉满整条进度条（时间文字贴左缘）。应跟随指针居中。
    final time = tester.getRect(
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            w.data != null &&
            RegExp(r'^\d{2}:\d{2}$').hasMatch(w.data!),
      ),
    );
    expect(time.width, lessThan(80));
    expect(time.left, greaterThan(slider.width * 0.4));

    await mouse.removePointer();
  });

  testWidgets('播放条：悬停气泡渲染在容器之上，且不撑高播放条', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appPrefsProvider.overrideWith(_Prefs.new),
          playbackProvider.overrideWith(_FakePlayback.new),
          currentLyricsProvider.overrideWith((ref) async => _groups),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark().copyWith(
            extensions: const [
              AppChromeColors(
                playerBarBackground: Color(0xFF202020),
                playerBackground: Color(0xFF101010),
              ),
            ],
          ),
          home: const Scaffold(
            body: Center(
              child: SizedBox(width: 1200, height: 82, child: PlayerBar()),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final bar = tester.getRect(find.byType(PlayerBar));
    expect(bar.height, 82, reason: '气泡在 Overlay 中，不应撑高播放条容器');

    final slider = tester.getRect(find.byType(PlaybackSlider));
    final target = Offset(slider.left + slider.width * 0.5, slider.center.dy);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: target);
    await tester.pump();
    await mouse.moveTo(target);
    await tester.pumpAndSettle();

    // 指针在中部（≈10s）→ 显示 2s 起的「第二行」（当前播放位置 0s）。
    final bubble = tester.getRect(find.text('第二行'));
    expect(bubble.bottom, lessThan(bar.top), reason: '气泡应渲染在播放条容器之上');
    await mouse.removePointer();
  });

  testWidgets('showTimes：时间标签与滑块之间留出间距', (tester) async {
    await _pump(tester, showTimes: true);
    final left = tester.getRect(find.text('00:00'));
    final slider = tester.getRect(find.byType(PlaybackSlider));
    // 左侧时间右缘与滑块左缘之间应留出 _timeGap（12px）。
    expect(slider.left - left.right, closeTo(12, 0.5));
  });
}
