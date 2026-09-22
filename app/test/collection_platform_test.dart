// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 「收藏 / 我喜欢」平台注册表测试：注册项、分类 Tab、红心键归一、能力位。
///
/// 两个页面与 `LikedStore`/`LikeController` 的行为都由本注册表驱动；这里锁定
/// 各平台声明，避免以后改注册项时悄悄改变页面形态或红心路由。
library;

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/l10n/generated/app_localizations.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/widgets/dialogs/collection_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final l10n = lookupAppLocalizations(const Locale('zh'));

  test('已注册平台与未注册回退 NT', () {
    for (final s in const ['netease', 'kugou', 'qqmusic', 'neko']) {
      expect(collectionPlatform(s).source, s, reason: '$s 未注册或错位');
    }
    expect(collectionPlatform('streaming').source, 'netease');
    expect(collectionPlatform('subsonic').source, 'netease');
  });

  test('分类 Tab：tabs() 与 tabIds 一致，且含默认项', () {
    expect(collectionPlatform('netease').tabIds, [
      'playlist',
      'album',
      'artist',
    ]);
    expect(collectionPlatform('kugou').tabIds, [
      'created',
      'collectedPlaylist',
      'collectedAlbum',
    ]);
    expect(collectionPlatform('qqmusic').tabIds, [
      'created',
      'collectedPlaylist',
      'liked',
    ]);
    expect(collectionPlatform('neko').tabIds, [
      'created',
      'collectedPlaylist',
      'liked',
    ]);

    for (final s in const ['netease', 'kugou', 'qqmusic', 'neko']) {
      final p = collectionPlatform(s);
      expect(p.tabs(l10n).map((t) => t.id).toList(), p.tabIds);
      expect(p.tabIds.contains(p.defaultTabId), isTrue);
      expect(p.tabKey(p.defaultTabId), '$s.${p.defaultTabId}');
    }
  });

  test('红心键归一（KG 小写 hash / 其余 id）', () {
    Track t(String source) => Track(id: 'AbC', title: 'x', source: source);
    expect(collectionPlatform('netease').likeKey(t('netease')), 'AbC');
    expect(collectionPlatform('neko').likeKey(t('neko')), 'AbC');
    expect(collectionPlatform('kugou').likeKey(t('kugou')), 'abc');
    expect(collectionPlatform('qqmusic').likeKey(t('qqmusic')), 'AbC');
  });

  test('本机库 / 对账能力位', () {
    expect(collectionPlatform('qqmusic').localLikedStore, isTrue);
    expect(collectionPlatform('qqmusic').reconcileLiked, isFalse);
    for (final s in const ['netease', 'kugou', 'neko']) {
      expect(collectionPlatform(s).localLikedStore, isFalse);
      expect(collectionPlatform(s).reconcileLiked, isTrue);
    }
  });
}
