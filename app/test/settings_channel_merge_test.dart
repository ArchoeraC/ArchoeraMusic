// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 回归：设置 →「音频效果」→「声道」的多声道合并开关。
///
/// 覆盖三件事：
///   1. 文案走 l10n（中文 / 英文两种 locale 都能渲染）；
///   2. 开关状态跟随偏好，点击后写回偏好；
///   3. 点击会触发 `applyAudioEffects()`（即时下发引擎）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/playback/playback_notifier.dart';
import 'package:archoera_music/services/playback/playback_state.dart';
import 'package:archoera_music/settings/settings_widgets.dart';
import 'package:archoera_music/settings/settings_sections.dart';
import 'package:archoera_music/stores/app_prefs.dart';

/// 不落盘、不读真实 prefs.json 的偏好控制器。
class _FakePrefsNotifier extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();

  @override
  void setChannelMerge(bool value) {
    state = state.copyWithChannelMerge(value);
  }
}

/// 只记录下发次数，不建引擎/不写会话记忆。
class _FakePlaybackNotifier extends PlaybackNotifier {
  int applyCount = 0;

  @override
  PlaybackState build() => const PlaybackState();

  @override
  Future<void> applyAudioEffects() async {
    applyCount++;
  }
}

Widget _wrap(ProviderContainer container, Locale locale) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(
        body: SingleChildScrollView(child: AudioEffectsSection()),
      ),
    ),
  );
}

/// 找到「多声道合并」所在的开关行。
Finder _channelMergeTile(String titleText) => find.ancestor(
  of: find.text(titleText),
  matching: find.byType(SettingSwitchTile),
);

void main() {
  testWidgets('多声道合并开关：默认关、点击后写偏好并下发', (tester) async {
    final playback = _FakePlaybackNotifier();
    final container = ProviderContainer(
      overrides: [
        appPrefsProvider.overrideWith(_FakePrefsNotifier.new),
        playbackProvider.overrideWith(() => playback),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(container, const Locale('zh', 'CN')));
    await tester.pumpAndSettle();

    // 小节标题与开关文案来自 ARB。
    expect(find.text('声道'), findsOneWidget);
    expect(find.text('多声道合并'), findsOneWidget);
    expect(find.text('已停用（保持原始立体声）'), findsOneWidget);

    final tile = _channelMergeTile('多声道合并');
    final switchFinder = find.descendant(of: tile, matching: find.byType(Switch));
    expect(tester.widget<Switch>(switchFinder).value, isFalse);

    await tester.ensureVisible(switchFinder);
    await tester.pumpAndSettle();
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(switchFinder).value, isTrue);
    expect(container.read(appPrefsProvider).channelMergeEnabled, isTrue);
    expect(find.text('已启用（所有声道合并为单声道输出）'), findsOneWidget);
    expect(playback.applyCount, 1);
  });

  testWidgets('多声道合并文案有英文翻译', (tester) async {
    final container = ProviderContainer(
      overrides: [
        appPrefsProvider.overrideWith(_FakePrefsNotifier.new),
        playbackProvider.overrideWith(_FakePlaybackNotifier.new),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(container, const Locale('en')));
    await tester.pumpAndSettle();

    expect(find.text('Channels'), findsOneWidget);
    expect(find.text('Channel merge'), findsOneWidget);
    expect(find.text('Off (original stereo preserved)'), findsOneWidget);
  });
}
