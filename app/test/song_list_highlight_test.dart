// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌曲列表搜索结果高亮的**widget 冒烟测试**。
///
/// 断言：
/// - 不传 `highlightOf`（默认 null）→ 行标题为普通 `Text`（`textSpan == null`），
///   即关闭态 / 非搜索态渲染与旧实现一致；
/// - 传 `highlightOf` 且有命中 → 标题为 `Text.rich`（`textSpan != null`）且命中
///   段叠加高亮背景；纯文本内容不变；
/// - 传 `highlightOf` 但无命中（区间为空）→ 同样回退普通 `Text`，不报错。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/search/search_highlight.dart';
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

Widget _wrap({List<MatchRange> Function(String)? highlightOf}) => ProviderScope(
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
          highlightOf: highlightOf,
        ),
      ),
    ),
  ),
);

/// 找到纯文本化后等于 [plain] 的 [Text] 组件。
Finder _textWithPlain(String plain) => find.byWidgetPredicate(
  (w) => w is Text && w.textSpan?.toPlainText() == plain,
);

/// 收集 [span] 及其子 span 中的叶子文本 span。
List<TextSpan> _leaves(InlineSpan span) {
  if (span is TextSpan) {
    if (span.children == null || span.children!.isEmpty) return [span];
    return [for (final c in span.children!) ..._leaves(c)];
  }
  return const [];
}

void main() {
  testWidgets('默认（highlightOf 为 null）：标题为普通 Text，渲染不变', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    final title = tester.widget<Text>(find.text('Love Story'));
    expect(title.data, 'Love Story');
    expect(title.textSpan, isNull, reason: '无高亮时不应改为 Text.rich');
  });

  testWidgets('有高亮入参 + 命中：标题为 Text.rich，命中段叠加背景', (tester) async {
    await tester.pumpWidget(_wrap(highlightOf: SearchHighlighter('love').call));
    await tester.pumpAndSettle();

    final richTitle = tester.widget<Text>(_textWithPlain('Love Story'));
    expect(richTitle.textSpan, isNotNull);
    expect(richTitle.textSpan!.toPlainText(), 'Love Story');

    final leaves = _leaves(richTitle.textSpan!);
    final highlighted = leaves.where(
      (s) => s.style?.backgroundColor != null,
    );
    expect(highlighted.map((s) => s.text), contains('Love'));
  });

  testWidgets('有高亮入参但无命中：回退普通 Text，不报错', (tester) async {
    await tester.pumpWidget(
      _wrap(highlightOf: (text) => highlightRanges(text, 'zzzz')),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final title = tester.widget<Text>(find.text('Love Story'));
    expect(title.textSpan, isNull);
  });
}
