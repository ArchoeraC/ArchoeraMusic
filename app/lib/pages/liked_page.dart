// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/liked/liked_loader.dart';
import '../services/netease/track.dart';
import '../services/playback/playback_notifier.dart';
import '../services/qqmusic/qq_liked_store.dart';
import '../services/qqmusic/qqmusic_api.dart' show kQqFavExperimental;
import '../stores/providers.dart';
import '../../l10n/l10n.dart';
import '../l10n/generated/app_localizations.dart';
import '../widgets/dialogs/kugou_login_button.dart';
import '../widgets/dialogs/netease_login_dialog.dart';
import '../widgets/dialogs/qqmusic_login_dialog.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/streaming/empty_state.dart';
import '../widgets/list/song_list.dart';
import '../widgets/common/toast.dart';
import '../widgets/dialogs/track_context_menu.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'liked/liked_page_actions.dart';
part 'liked/liked_page_view.dart';

/// 我喜欢页（对齐原项目 Liked.vue）。
///
/// 平台切换（NT / KG / QM）：
/// - NT / KG：登录对应平台后拉取「红心收藏」/ KG「我喜欢」歌单
///   → SongList 可播放（走 [LikedStore]，SQLite 缓存秒开 + SWR 全量刷新）；
/// - QM：**本机红心为主**（[QqLikedStore]，离线始终可用）——在搜索 /
///   播放页给任意 QQ 曲目点亮红心即出现在此并可播放；登录 QQ 后可手动
///   「同步在线收藏」（实验性社区逆向 dirid=201 接口，失败不影响本机）。
///
/// 数据加载：NT/KG走 [LikedStore]（见 liked_loader.dart 注释），
/// QQ 走 [QqLikedStore]（见 qq_liked_store.dart：本机 JSON + 在线并入）。
class LikedPage extends ConsumerStatefulWidget {
  const LikedPage({super.key});

  @override
  ConsumerState<LikedPage> createState() => _LikedPageState();
}

class _LikedPageState extends ConsumerState<LikedPage> {
  static const _qqPlatform = 'qqmusic';

  String _platform = 'netease';
  bool _resolving = false;

  bool get _neteaseLoggedIn => ref.read(neteaseAuthProvider) != null;
  bool get _kugouLoggedIn => ref.read(kugouApiProvider).session != null;
  bool get _qqLoggedIn => ref.read(qqMusicApiProvider).isLoggedIn;

  /// NT / KG平台需对应账号登录；QQ 平台本机红心优先、不要求登录。
  bool get _requiresLogin => _platform != _qqPlatform;

  /// 当前平台是否「可用」（内容区据此显示数据 / 登录引导 / 本机列表）。
  bool get _loggedIn => _requiresLogin
      ? (_platform == 'kugou' ? _kugouLoggedIn : _neteaseLoggedIn)
      : true;

  @override
  void initState() {
    super.initState();
    // 默认选已登录平台（NT优先；无NT/KG但已登录 QQ → QQ 本机
    // 红心；都未登录保持NT引导）
    if (!_neteaseLoggedIn && _kugouLoggedIn) {
      _platform = 'kugou';
    } else if (!_neteaseLoggedIn && !_kugouLoggedIn && _qqLoggedIn) {
      _platform = _qqPlatform;
    }
    if (_loggedIn) _ensureLoaded(_platform);
  }

  LikedStore get _store => ref.read(likedStoreProvider);
  QqLikedStore get _qqStore => ref.read(qqLikedStoreProvider);

  List<Track> _tracks(String platform) =>
      platform == _qqPlatform ? _qqStore.tracks : _store.tracks(platform);

  @override
  Widget build(BuildContext context) => _buildPage(context);
}
