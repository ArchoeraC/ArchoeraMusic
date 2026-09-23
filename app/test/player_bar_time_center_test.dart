// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放条：迷你歌词/频谱都不可用时，时间应在条内垂直居中（占位收起）。
///
/// 回归背景：播放条右侧 Column 原为「时间 + 4px + 120×12 迷你区」。即便
/// 关闭「播放条歌词」与「播放条频谱」，迷你区仍固定占 12px（SpectrumView
/// 禁用时返回等高空盒），导致时间被顶高、不居中。现改为内容为空时收起
/// （AnimatedSize 过渡），时间随列在主体行内居中。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/playback/playback_notifier.dart';
import 'package:archoera_music/services/playback/playback_state.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/theme/app_theme.dart';
import 'package:archoera_music/widgets/layout/player_bar.dart';

class _StubPrefs extends AppPrefsNotifier {
  _StubPrefs(this._value);
  final AppPrefs _value;
  @override
  AppPrefs build() => _value;
}

/// 只有「有源」的最小播放态，让播放条本体渲染（不启引擎）。
class _StubPlayback extends PlaybackNotifier {
  @override
  PlaybackState build() =>
      const PlaybackState(source: 'test', title: 'T', subtitle: 'A');
}

Finder _timeText() => find.byWidgetPredicate(
  (w) =>
      w is Text &&
      w.data != null &&
      RegExp(r'^\d{1,3}:\d{2}').hasMatch(w.data!.trim()),
);

Future<void> _pumpBar(WidgetTester tester, Map<String, dynamic> data) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appPrefsProvider.overrideWith(
          () => _StubPrefs(AppPrefs(initialData: data)),
        ),
        playbackProvider.overrideWith(_StubPlayback.new),
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
}

void main() {
  testWidgets('关闭播放条歌词/频谱后，时间下移到主体行居中（占位收起）', (tester) async {
    // 迷你频谱开启：时间被下方 12px+4px 迷你区顶高。
    await _pumpBar(tester, {
      'player.barLyrics': false,
      'player.barSpectrum': true,
    });
    final bar = tester.getRect(find.byType(PlayerBar));
    final withInfo = tester.getRect(_timeText());
    // 主体行中线 = 顶部 22px 进度条 + 60px 主体行的一半。
    final mainRowCenter = bar.top + 22 + 30;
    expect(
      withInfo.center.dy,
      lessThan(mainRowCenter - 4),
      reason: '有迷你区时时间应被顶到主体行中线之上',
    );

    // 关闭迷你频谱：迷你区收起，时间应回到主体行中线。
    await tester.pumpWidget(const SizedBox.shrink());
    tester.takeException();
    await _pumpBar(tester, {
      'player.barLyrics': false,
      'player.barSpectrum': false,
    });
    final withoutInfo = tester.getRect(_timeText());
    expect(
      withoutInfo.center.dy,
      closeTo(mainRowCenter, 2),
      reason: '迷你区收起后时间应垂直居中',
    );
    expect(
      withoutInfo.center.dy,
      greaterThan(withInfo.center.dy + 4),
      reason: '收起后时间应相对下移',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    tester.takeException();
  });
}
