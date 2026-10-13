// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌曲列表**歌词命中片段**行内展示的 widget 冒烟测试。
///
/// 断言：
/// - 不传 `lyricSnippetOf`（默认 null）→ 不显示片段，渲染与旧实现一致；
/// - 传 `lyricSnippetOf` 且有片段 → 行内以次要样式显示该片段（单行省略）；
/// - 片段为空串 → 不显示（不占位）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/widgets/list/song_list.dart';

/// 测试用偏好：不落盘（避免测试写入真实 prefs.json）。
class _FakeAppPrefsNotifier extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();
}

const Track _track = Track(
  id: '1',
  title: 'Love Story',
  artists: [TrackArtist(name: 'Taylor Swift')],
  album: TrackAlbum(name: 'Fearless'),
  source: 'local',
  localPath: '/tmp/does-not-exist.mp3',
);

Widget _wrap({String? Function(Track)? lyricSnippetOf}) => ProviderScope(
  overrides: [appPrefsProvider.overrideWith(_FakeAppPrefsNotifier.new)],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SizedBox(
        width: 900,
        height: 400,
        child: SongList(
          items: const [_track],
          onPlay: (_) {},
          lyricSnippetOf: lyricSnippetOf,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('默认（lyricSnippetOf 为 null）：不显示歌词片段', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('…我爱你中国…'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有片段：行内显示该片段（次要样式、单行省略）', (tester) async {
    await tester.pumpWidget(
      _wrap(lyricSnippetOf: (_) => '…我爱你中国…'),
    );
    await tester.pumpAndSettle();

    expect(find.text('…我爱你中国…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('片段为空串：不显示', (tester) async {
    await tester.pumpWidget(_wrap(lyricSnippetOf: (_) => ''));
    await tester.pumpAndSettle();

    expect(find.text('…我爱你中国…'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
