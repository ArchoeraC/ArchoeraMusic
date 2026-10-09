// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌曲列表 ink 裁剪集成回归测试。
///
/// 断言 `SongList` 的滚动列表确实被 `InkClip` 包裹（透明 Material + 裁剪）。
/// 若有人误删列表裁剪，行内 InkWell 的悬停高亮又会越界画到列表上下边界之外，
/// 本测试即失败。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/stores/app_prefs.dart';
import 'package:archoera_music/widgets/common/ink_clip.dart';
import 'package:archoera_music/widgets/list/song_list.dart';

/// 测试用偏好：不落盘（避免测试写入真实 prefs.json）。
class _FakeAppPrefsNotifier extends AppPrefsNotifier {
  @override
  AppPrefs build() => AppPrefs();
}

void main() {
  testWidgets('SongList 的歌曲列表被 InkClip 包裹', (tester) async {
    const track = Track(
      id: '1',
      title: 'Test Track',
      artists: [TrackArtist(name: 'Artist')],
      source: 'local',
      localPath: '/tmp/does-not-exist.mp3',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appPrefsProvider.overrideWith(_FakeAppPrefsNotifier.new)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 640,
              height: 400,
              child: SongList(items: const [track], onPlay: (_) {}),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(SongList), findsOneWidget);
    // 列表视口应被 InkClip 包裹（透明 Material + Clip.hardEdge）。
    final clip = find.byType(InkClip);
    expect(clip, findsWidgets);
    final material = tester.widget<Material>(
      find.descendant(of: clip.first, matching: find.byType(Material)).first,
    );
    expect(material.type, MaterialType.transparency);
    expect(material.clipBehavior, Clip.hardEdge);
  });
}
