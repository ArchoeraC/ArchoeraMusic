// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 整幅封面布局：关闭歌词时的排版回归。
/// - 不再构建歌词组件；
/// - 曲目信息在 autoCenterCover 开启时垂直居中，关闭时保持顶部。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/pages/player/layouts/player_layout.dart';
import 'package:archoera_music/pages/player/layouts/poster_layout.dart';
import 'package:archoera_music/widgets/player/lyrics_view.dart';

PlayerLayoutContext _ctx({
  required bool autoCenterCover,
  required AnimationController pulse,
}) => PlayerLayoutContext(
  current: null,
  coverKey: 'local:test',
  title: '测试曲目',
  subtitle: '测试歌手',
  playing: false,
  hasContent: true,
  hasLyrics: true,
  showLyrics: false,
  contentMounted: true,
  transitionStyle: 'scale',
  coverLyricRatio: 0.45,
  autoCenterCover: autoCenterCover,
  slideNext: true,
  coverPulse: pulse,
  beatStrength: 1,
  pageWidth: 1200,
  pageHeight: 720,
  fullscreenCoverWidth: 624,
  chromeOpacity: 1,
  buffering: false,
  hasSource: true,
  onDragChanged: (_) {},
  onSeekEnd: (_) {},
  l10n: lookupAppLocalizations(const Locale('zh')),
  onSeekLyric: null,
  dragMs: null,
);

Future<void> _pump(WidgetTester tester, {required bool autoCenterCover}) async {
  final pulse = AnimationController(
    vsync: const TestVSync(),
    duration: const Duration(milliseconds: 100),
  );
  addTearDown(pulse.dispose);
  final ctx = _ctx(autoCenterCover: autoCenterCover, pulse: pulse);
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

void main() {
  testWidgets('关闭歌词：不构建歌词，信息留在右栏', (tester) async {
    await _pump(tester, autoCenterCover: true);
    expect(find.byType(LyricsView), findsNothing);
    expect(find.text('测试曲目'), findsOneWidget);
  });

  testWidgets('关闭歌词 + 自动居中：信息垂直居中', (tester) async {
    await _pump(tester, autoCenterCover: true);
    final center = tester.getCenter(find.text('测试曲目'));
    expect(center.dy, greaterThan(280));
    expect(center.dy, lessThan(440));
  });

  testWidgets('关闭歌词 + 关闭自动居中：信息保持顶部', (tester) async {
    await _pump(tester, autoCenterCover: false);
    final center = tester.getCenter(find.text('测试曲目'));
    expect(center.dy, lessThan(180));
  });
}
