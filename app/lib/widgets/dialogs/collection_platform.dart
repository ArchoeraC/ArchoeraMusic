// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 「收藏 / 我喜欢」平台注册表。
///
/// 我喜欢页、收藏页、`LikedStore`、`LikeController` 都只面向本文件的
/// [CollectionPlatform] 接口，不再出现具体平台分支。**新增音源 = 实现一个
/// [CollectionPlatform] 并放进 [_registry]**，两个页面与数据面无需改动。
///
/// 每个适配器负责该源的全部差异：
/// - 平台元信息：标签、是否启用（实验源开关）、登录态、登录动作；
/// - 我喜欢（红心）：红心键归一、id 集合、全量列表、收藏/取消、对账、
///   本机库（QQ）等；
/// - 收藏页：分类 Tab、拉取、点击打开、副标题/空态/登录文案。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../services/neko/neko_types.dart';
import '../../services/netease/netease_api.dart';
import '../../services/netease/track.dart';
import '../../services/qqmusic/qq_liked_store.dart';
import '../../services/qqmusic/qqmusic_api.dart';
import '../../stores/app_prefs.dart';
import '../../stores/providers.dart';
import '../../stores/shell_page_state.dart';
import '../common/toast.dart';
import 'kugou_login_button.dart';
import 'neko_login_dialog.dart';
import 'netease_login_dialog.dart';
import 'qqmusic_login_dialog.dart';
import 'track_list_dialog.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

/// 收藏页的一个分类 Tab。
class CollectionTab {
  const CollectionTab(this.id, this.label, this.icon, {this.extent = 180});

  final String id;
  final String Function(AppLocalizations l10n) label;
  final IconData icon;

  /// 网格最大列宽（NT 歌手用小封面）。
  final double extent;
}

/// 我喜欢页当前平台的数据视图（屏蔽服务端 store / 本机库差异）。
class LikedView {
  const LikedView({
    required this.tracks,
    required this.total,
    required this.loaded,
    required this.loading,
    required this.error,
    required this.likeIds,
  });

  final List<Track> tracks;
  final int total;
  final bool loaded;
  final bool loading;
  final String error;

  /// 红心填充态判定用的键集。
  final Set<String> likeIds;
}

/// 单个音源的「收藏 / 我喜欢」适配器。
abstract class CollectionPlatform {
  /// 平台标识（与 `Track.source` 对齐）。
  String get source;

  /// 平台展示名（本地化）。
  String label(AppLocalizations l10n);

  /// 是否启用（实验源由设置开关控制；默认恒启用）。
  bool enabled(dynamic ref) => true;

  /// 是否已登录（收藏页 / 我喜欢页的登录门槛）。
  bool loggedIn(dynamic ref);

  /// 登录动作（弹对应平台登录框）。
  Future<void> login(BuildContext context);

  /// 登录态信号（页面据此监听并在变化时重置/重载）。
  dynamic get authSignal;

  /// 红心操作失败时的提示文案。
  String likeFailedText(AppLocalizations l10n);

  /// 「我喜欢」是否可用（QQ 本机红心无需登录 → true；默认同 [loggedIn]）。
  bool likedAvailable(dynamic ref) => loggedIn(ref);

  // ── 我喜欢（红心） ────────────────────────────────────────────────

  /// 本机红心库（QQ）：列表/状态不经服务端，离线可用。
  bool get localLikedStore => false;

  /// 红心键（跨端稳定标识；NT/NK=id，KG=hash，QQ=songmid）。
  String likeKey(Track t);

  /// 是否参与权威列表对账（QQ 本机列表不走对账）。
  bool get reconcileLiked => !localLikedStore;

  /// 缓存 user key（NT uid / KG userid / NK userId / QQ 'local'）。
  String? likedUserKey(dynamic ref);

  /// 轻量红心 id 集合（启动同步用）。
  Future<Set<String>> fetchLikedIds(dynamic ref);

  /// 全量「我喜欢的」曲目（`LikedStore` 用）。
  Future<List<Track>> fetchLikedTracks(dynamic ref);

  /// 收藏 / 取消收藏（乐观更新由 `LikeController` 负责，这里只做调用）。
  Future<void> setLiked(dynamic ref, Track t, bool like);

  /// 我喜欢页展示视图（服务端 store / 本机库）。
  LikedView likedView(dynamic ref);

  /// 登录态变化时的处理（重置；QQ 本机库无需处理）。
  void resetLiked(dynamic ref) {}

  /// 进入页面时的加载（QQ 会顺带并入在线收藏）。
  void ensureLikedLoaded(dynamic ref);

  /// 刷新按钮文案（QQ 为「同步在线收藏」）。
  String likedRefreshLabel(AppLocalizations l10n) => l10n.commonRefresh;

  /// 刷新按钮是否显示。
  bool likedShowRefresh(dynamic ref, LikedView view) =>
      view.loaded && view.tracks.isNotEmpty;

  /// 刷新动作。
  Future<void> likedRefresh(BuildContext context, dynamic ref);

  /// 空态额外动作（QQ 登录/同步）；无 → null。
  ({String label, Future<void> Function(BuildContext, dynamic) run})?
  likedEmptyAction(AppLocalizations l10n, dynamic ref) => null;

  /// 副标题（未登录提示 / 歌曲数）；需要 ref 以读取本平台可用性。
  String likedSubtitle(dynamic ref, AppLocalizations l10n, LikedView view);

  String likedLoginDesc(AppLocalizations l10n);
  String likedEmptyTitle(AppLocalizations l10n) => l10n.pageLikedEmpty;
  String likedEmptyHint(AppLocalizations l10n);

  // ── 收藏页 ──────────────────────────────────────────────────────

  /// 该平台的分类 Tab（顺序即展示顺序）。
  List<CollectionTab> tabs(AppLocalizations l10n);

  /// 分类 id 列表（无 l10n 依赖；恢复选择时校验用）。
  List<String> get tabIds;

  /// 该平台在收藏页的分类选择（跨壳内容卸载/重挂载保留）。
  NotifierProvider<ShellPageSelection<String>, String?> get tabSelection;

  String get defaultTabId;

  /// 拉取某分类；返回「tabKey → 数据」映射（一次请求可填充多个分类，
  /// 如 KG/QQ/NK 的曲库接口）。key 形如 `'$source.$tabId'`。
  Future<Map<String, List<CoverItem>>> fetchFavorites(dynamic ref, String tabId);

  /// 点击某个封面项的打开动作。
  void openFavorite(
    BuildContext context,
    dynamic ref,
    String tabId,
    CoverItem item,
  );

  /// 分类副标题（登录提示 / 计数）。
  String favTabSubtitle(
    AppLocalizations l10n,
    String tabId,
    int count,
    bool loggedIn,
  );

  String favLoginDesc(AppLocalizations l10n);
  String favEmptyHint(AppLocalizations l10n);

  /// 该分类的缓存键。
  String tabKey(String tabId) => '$source.$tabId';
}

/// 按 `Track.source` 取适配器；未注册源回退 NT（与红心默认路由一致）。
CollectionPlatform collectionPlatform(String source) =>
    _registry[source] ?? _registry['netease']!;

/// 已启用平台的适配器（顺序即下拉顺序）。
List<CollectionPlatform> collectionPlatforms(dynamic ref) =>
    _all.where((p) => p.enabled(ref)).toList(growable: false);

/// 默认「我喜欢」平台：优先已登录的 NT → KG → QQ，否则 NT（与历史一致；
/// QQ 虽「本机可用」，但未登录时默认仍回 NT 引导登录）。
String defaultLikedPlatform(dynamic ref) {
  final nt = collectionPlatform('netease');
  final kg = collectionPlatform('kugou');
  final qq = collectionPlatform('qqmusic');
  final ntIn = nt.loggedIn(ref);
  final kgIn = kg.loggedIn(ref);
  if (!ntIn && kgIn) return 'kugou';
  if (!ntIn && !kgIn && qq.loggedIn(ref)) return 'qqmusic';
  return 'netease';
}

final List<CollectionPlatform> _all = [
  _NeteaseCollection(),
  _KugouCollection(),
  _QqCollection(),
  _NekoCollection(),
];

final Map<String, CollectionPlatform> _registry = {
  for (final p in _all) p.source: p,
};

// ── NT ─────────────────────────────────────────────────────────────────

class _NeteaseCollection extends CollectionPlatform {
  @override
  String get source => 'netease';

  @override
  String label(AppLocalizations l10n) => l10n.platformNetease;

  @override
  dynamic get authSignal =>
      neteaseAuthProvider.select<Object?>((a) => a?.userId);

  @override
  String likeFailedText(AppLocalizations l10n) =>
      l10n.toastLoginRequiredNetease;

  @override
  NotifierProvider<ShellPageSelection<String>, String?> get tabSelection =>
      favoritesNeteaseTabProvider;

  @override
  List<String> get tabIds => const ['playlist', 'album', 'artist'];

  @override
  bool loggedIn(dynamic ref) => ref.read(neteaseAuthProvider) != null;

  @override
  Future<void> login(BuildContext context) =>
      showNeteaseLoginDialog(context);

  @override
  String likeKey(Track t) => t.id;

  @override
  String? likedUserKey(dynamic ref) => ref.read(neteaseAuthProvider)?.userId;

  @override
  Future<Set<String>> fetchLikedIds(dynamic ref) async {
    final account = ref.read(neteaseAuthProvider);
    if (account == null) return const {};
    return (await ref.read(neteaseApiProvider).likedIds(account.userId))
        .toSet();
  }

  @override
  Future<List<Track>> fetchLikedTracks(dynamic ref) async {
    final account = ref.read(neteaseAuthProvider);
    if (account == null) return const [];
    return ref.read(neteaseApiProvider).likedSongs(account.userId);
  }

  @override
  Future<void> setLiked(dynamic ref, Track t, bool like) =>
      ref.read(neteaseApiProvider).like(t.id, like: like);

  @override
  LikedView likedView(dynamic ref) {
    final store = ref.read(likedStoreProvider);
    return LikedView(
      tracks: store.tracks(source),
      total: store.total(source),
      loaded: store.loaded(source),
      loading: store.loading(source),
      error: store.error(source),
      likeIds: ref.read(likeControllerProvider).idsFor(source),
    );
  }

  @override
  void resetLiked(dynamic ref) => ref.read(likedStoreProvider).reset(source);

  @override
  void ensureLikedLoaded(dynamic ref) =>
      ref.read(likedStoreProvider).ensureLoaded(source);

  @override
  Future<void> likedRefresh(BuildContext context, dynamic ref) =>
      ref.read(likedStoreProvider).refresh(source, writeCache: true);

  @override
  String likedSubtitle(dynamic ref, AppLocalizations l10n, LikedView view) =>
      likedAvailable(ref)
      ? l10n.commonSongCountHint(count: view.total)
      : l10n.pageLikedNeteaseLoginHint;

  @override
  String likedLoginDesc(AppLocalizations l10n) =>
      l10n.pageLikedNeteaseLoginDesc;

  @override
  String likedEmptyHint(AppLocalizations l10n) =>
      l10n.pageLikedNeteaseEmptyHint;

  @override
  List<CollectionTab> tabs(AppLocalizations l10n) => [
    CollectionTab('playlist', (l) => l.commonPlaylists, EtaIcons.playlist),
    CollectionTab('album', (l) => l.commonAlbums, EtaIcons.albumOutline),
    CollectionTab('artist', (l) => l.commonArtists, EtaIcons.userOutline, extent: 150),
  ];

  @override
  String get defaultTabId => 'playlist';

  @override
  Future<Map<String, List<CoverItem>>> fetchFavorites(
    dynamic ref,
    String tabId,
  ) async {
    final account = ref.read(neteaseAuthProvider);
    final api = ref.read(neteaseApiProvider);
    final items = switch (tabId) {
      'album' => await api.albumSublist(),
      'artist' => await api.artistSublist(),
      _ =>
        (await api.userPlaylists(account!.userId))
            .where((p) => p.subscribed)
            .map(
              (p) => CoverItem(
                id: p.id,
                title: p.name,
                cover: p.cover,
                subtitle: p.owner ?? '',
                trackCount: p.trackCount,
              ),
            )
            .toList(),
    };
    return {tabKey(tabId): items};
  }

  @override
  void openFavorite(
    BuildContext context,
    dynamic ref,
    String tabId,
    CoverItem item,
  ) {
    switch (tabId) {
      case 'album':
        showNeteaseAlbumDialog(context, item);
      case 'artist':
        showNeteaseArtistDialog(context, item);
      default:
        showPlaylistDetailDialog(context, item);
    }
  }

  @override
  String favTabSubtitle(
    AppLocalizations l10n,
    String tabId,
    int count,
    bool loggedIn,
  ) {
    if (!loggedIn) {
      return switch (tabId) {
        'album' => l10n.pageFavAlbumLoginHint,
        'artist' => l10n.pageFavArtistLoginHint,
        _ => l10n.pageFavPlaylistLoginHint,
      };
    }
    return switch (tabId) {
      'album' => l10n.pageFavAlbumCount(count: count),
      'artist' => l10n.pageFavArtistCount(count: count),
      _ => l10n.pageFavPlaylistCount(count: count),
    };
  }

  @override
  String favLoginDesc(AppLocalizations l10n) => l10n.pageFavLoginDesc;

  @override
  String favEmptyHint(AppLocalizations l10n) => l10n.pageFavEmptyHint;
}

// ── KG ─────────────────────────────────────────────────────────────────

class _KugouCollection extends CollectionPlatform {
  @override
  String get source => 'kugou';

  @override
  String label(AppLocalizations l10n) => l10n.platformKugou;

  @override
  dynamic get authSignal =>
      kugouApiProvider.select<Object?>((s) => s.session?.userid);

  @override
  String likeFailedText(AppLocalizations l10n) =>
      l10n.toastLoginRequiredKugou;

  @override
  NotifierProvider<ShellPageSelection<String>, String?> get tabSelection =>
      favoritesKugouTabProvider;

  @override
  List<String> get tabIds =>
      const ['created', 'collectedPlaylist', 'collectedAlbum'];

  @override
  bool loggedIn(dynamic ref) => ref.read(kugouApiProvider).session != null;

  @override
  Future<void> login(BuildContext context) async {
    await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      barrierDismissible: false,
      builder: (_) => const KgQrLoginDialog(),
    );
  }

  @override
  String likeKey(Track t) => (t.kugou?.hash ?? t.id).toLowerCase();

  @override
  String? likedUserKey(dynamic ref) => ref.read(kugouApiProvider).session?.userid;

  @override
  Future<Set<String>> fetchLikedIds(dynamic ref) =>
      ref.read(kugouApiProvider).likedHashSet();

  @override
  Future<List<Track>> fetchLikedTracks(dynamic ref) =>
      ref.read(kugouApiProvider).likedTracks();

  @override
  Future<void> setLiked(dynamic ref, Track t, bool like) {
    final api = ref.read(kugouApiProvider);
    return like ? api.addToLike(t) : api.removeFromLike(t);
  }

  @override
  LikedView likedView(dynamic ref) {
    final store = ref.read(likedStoreProvider);
    return LikedView(
      tracks: store.tracks(source),
      total: store.total(source),
      loaded: store.loaded(source),
      loading: store.loading(source),
      error: store.error(source),
      likeIds: ref.read(likeControllerProvider).idsFor(source),
    );
  }

  @override
  void resetLiked(dynamic ref) => ref.read(likedStoreProvider).reset(source);

  @override
  void ensureLikedLoaded(dynamic ref) =>
      ref.read(likedStoreProvider).ensureLoaded(source);

  @override
  Future<void> likedRefresh(BuildContext context, dynamic ref) =>
      ref.read(likedStoreProvider).refresh(source, writeCache: true);

  @override
  String likedSubtitle(dynamic ref, AppLocalizations l10n, LikedView view) =>
      likedAvailable(ref)
      ? l10n.commonSongCountHint(count: view.total)
      : l10n.pageLikedKugouLoginHint;

  @override
  String likedLoginDesc(AppLocalizations l10n) => l10n.pageLikedKugouLoginDesc;

  @override
  String likedEmptyHint(AppLocalizations l10n) => l10n.pageLikedKugouEmptyHint;

  @override
  List<CollectionTab> tabs(AppLocalizations l10n) => [
    CollectionTab('created', (l) => l.pageFavKgCreated, EtaIcons.music2Outline),
    CollectionTab(
      'collectedPlaylist',
      (l) => l.pageFavKgCollectedPlaylist,
      EtaIcons.music2Outline,
    ),
    CollectionTab(
      'collectedAlbum',
      (l) => l.pageFavKgCollectedAlbum,
      EtaIcons.music2Outline,
    ),
  ];

  @override
  String get defaultTabId => 'created';

  @override
  Future<Map<String, List<CoverItem>>> fetchFavorites(
    dynamic ref,
    String tabId,
  ) async {
    final lib = await ref.read(kugouApiProvider).userLibrary();
    // 一次 `/v7/get_all_list` 拉全部分类（切 tab 不再重复请求）。
    return {
      tabKey('created'): lib.createdPlaylists
          .map((i) => i.toCoverItem())
          .toList(),
      tabKey('collectedPlaylist'): lib.collectedPlaylists
          .map((i) => i.toCoverItem())
          .toList(),
      tabKey('collectedAlbum'): lib.collectedAlbums
          .map((i) => i.toCoverItem())
          .toList(),
    };
  }

  @override
  void openFavorite(
    BuildContext context,
    dynamic ref,
    String tabId,
    CoverItem item,
  ) {
    if (item.title == '我喜欢') {
      showKugouTracksDialog(
        context,
        title: item.title,
        cover: item.cover,
        loadTracks: (r) => r.read(kugouApiProvider).likedTracks(),
      );
      return;
    }
    showKugouPlaylistDetailDialog(context, item);
  }

  @override
  String favTabSubtitle(
    AppLocalizations l10n,
    String tabId,
    int count,
    bool loggedIn,
  ) {
    if (!loggedIn) {
      return switch (tabId) {
        'collectedPlaylist' => l10n.pageFavKgCollectedPlaylistLoginHint,
        'collectedAlbum' => l10n.pageFavKgCollectedAlbumLoginHint,
        _ => l10n.pageFavKgCreatedLoginHint,
      };
    }
    return switch (tabId) {
      'collectedPlaylist' => l10n.pageFavKgCollectedPlaylistCount(count: count),
      'collectedAlbum' => l10n.pageFavKgCollectedAlbumCount(count: count),
      _ => l10n.pageFavKgCreatedCount(count: count),
    };
  }

  @override
  String favLoginDesc(AppLocalizations l10n) => l10n.pageFavKugouLoginDesc;

  @override
  String favEmptyHint(AppLocalizations l10n) => l10n.pageFavKugouEmptyHint;
}

// ── QQ ─────────────────────────────────────────────────────────────────

class _QqCollection extends CollectionPlatform {
  @override
  String get source => 'qqmusic';

  @override
  String label(AppLocalizations l10n) => l10n.platformQQMusic;

  @override
  dynamic get authSignal =>
      qqMusicApiProvider.select<Object?>((s) => s.isLoggedIn);

  @override
  String likeFailedText(AppLocalizations l10n) => l10n.toastQqLikeSyncFailed;

  @override
  NotifierProvider<ShellPageSelection<String>, String?> get tabSelection =>
      favoritesQqTabProvider;

  @override
  List<String> get tabIds => const ['created', 'collectedPlaylist', 'liked'];

  @override
  bool loggedIn(dynamic ref) => ref.read(qqMusicApiProvider).isLoggedIn;

  @override
  bool likedAvailable(dynamic ref) => true; // 本机红心无需登录

  @override
  bool get localLikedStore => true;

  @override
  Future<void> login(BuildContext context) => showQqMusicLoginDialog(context);

  @override
  String likeKey(Track t) => qqLikeKey(t);

  @override
  String? likedUserKey(dynamic ref) => QqLikedStore.userKey;

  @override
  Future<Set<String>> fetchLikedIds(dynamic ref) async {
    final store = ref.read(qqLikedStoreProvider);
    await store.ensureLoaded();
    final local = store.midSet;
    if (!kQqFavExperimental || !loggedIn(ref)) return local;
    try {
      final online = await ref.read(qqMusicApiProvider).likedSongmids();
      return {...local, ...online};
    } catch (_) {
      return local;
    }
  }

  @override
  Future<List<Track>> fetchLikedTracks(dynamic ref) async {
    final store = ref.read(qqLikedStoreProvider);
    await store.ensureLoaded();
    return store.tracks;
  }

  @override
  Future<void> setLiked(dynamic ref, Track t, bool like) async {
    final key = qqLikeKey(t);
    if (key.isEmpty) return;
    final store = ref.read(qqLikedStoreProvider);
    if (kQqFavExperimental && loggedIn(ref)) {
      // 在线写失败 → 抛错（由 LikeController 回滚且不落本机库）。
      await ref.read(qqMusicApiProvider).like(key, like: like, songId: t.id);
    }
    if (like) {
      await store.add(t);
    } else {
      await store.removeByKey(key);
    }
  }

  @override
  LikedView likedView(dynamic ref) {
    final store = ref.read(qqLikedStoreProvider);
    return LikedView(
      tracks: store.tracks,
      total: store.tracks.length,
      loaded: store.loaded,
      loading: store.loading,
      error: store.error,
      likeIds: store.midSet,
    );
  }

  @override
  void ensureLikedLoaded(dynamic ref) {
    unawaited(ref.read(qqLikedStoreProvider).ensureLoaded());
    if (kQqFavExperimental && loggedIn(ref)) {
      unawaited(_mergeOnlineQuiet(ref));
    }
  }

  Future<void> _mergeOnlineQuiet(dynamic ref) async {
    try {
      final online = await ref.read(qqMusicApiProvider).likedSongs();
      await ref.read(qqLikedStoreProvider).mergeOnline(online);
      ref.read(likeControllerProvider).mergeOnlineQq(online);
    } catch (_) {
      // 静默：页内「同步在线收藏」按钮提供显式重试与提示
    }
  }

  @override
  String likedRefreshLabel(AppLocalizations l10n) =>
      l10n.pageLikedQqSyncOnline;

  @override
  bool likedShowRefresh(dynamic ref, LikedView view) =>
      view.loaded && (view.tracks.isNotEmpty || loggedIn(ref));

  @override
  Future<void> likedRefresh(BuildContext context, dynamic ref) =>
      _syncOnline(context, ref);

  Future<void> _syncOnline(BuildContext context, dynamic ref) async {
    final l10n = context.l10n;
    if (!kQqFavExperimental) {
      toast(l10n.toastQqLikeSyncFailed);
      return;
    }
    if (!loggedIn(ref)) {
      final ok = await showQqMusicLoginDialog(context);
      if (ok != true) return;
    }
    try {
      final online = await ref.read(qqMusicApiProvider).likedSongs();
      final n = await ref.read(qqLikedStoreProvider).mergeOnline(online);
      ref.read(likeControllerProvider).mergeOnlineQq(online);
      toast(
        n > 0 ? l10n.pageLikedQqSynced(count: n) : l10n.pageLikedQqSyncedNone,
      );
    } catch (_) {
      toast(l10n.toastQqLikeSyncFailed);
    }
  }

  @override
  ({String label, Future<void> Function(BuildContext, dynamic) run})?
  likedEmptyAction(AppLocalizations l10n, dynamic ref) {
    if (!loggedIn(ref)) {
      return (
        label: l10n.pageLikedQqLoginSync,
        run: (ctx, r) async => showQqMusicLoginDialog(ctx),
      );
    }
    return (label: l10n.pageLikedQqSyncOnline, run: _syncOnline);
  }

  @override
  String likedSubtitle(dynamic ref, AppLocalizations l10n, LikedView view) =>
      view.tracks.isEmpty
      ? l10n.pageLikedQqHint
      : l10n.commonSongCountHint(count: view.tracks.length);

  @override
  String likedLoginDesc(AppLocalizations l10n) =>
      l10n.pageLikedNeteaseLoginDesc;

  @override
  String likedEmptyTitle(AppLocalizations l10n) => l10n.pageLikedQqEmptyTitle;

  @override
  String likedEmptyHint(AppLocalizations l10n) => l10n.pageLikedQqEmptyHint;

  @override
  List<CollectionTab> tabs(AppLocalizations l10n) => [
    CollectionTab('created', (l) => l.pageFavKgCreated, EtaIcons.music2Outline),
    CollectionTab(
      'collectedPlaylist',
      (l) => l.pageFavKgCollectedPlaylist,
      EtaIcons.music2Outline,
    ),
    CollectionTab('liked', (l) => l.sidebarLiked, EtaIcons.music2Outline),
  ];

  @override
  String get defaultTabId => 'created';

  @override
  Future<Map<String, List<CoverItem>>> fetchFavorites(
    dynamic ref,
    String tabId,
  ) async {
    final lib = await ref.read(qqMusicApiProvider).userLibrary();
    return {
      tabKey('created'): lib.created,
      tabKey('collectedPlaylist'): lib.collected,
      tabKey('liked'): lib.likedTotal <= 0
          ? const []
          : [
              CoverItem(
                id: 'profile:favorites',
                title: '我喜欢',
                cover: lib.likedCover.isEmpty ? null : lib.likedCover,
                trackCount: lib.likedTotal,
                source: 'qqmusic',
              ),
            ],
    };
  }

  @override
  void openFavorite(
    BuildContext context,
    dynamic ref,
    String tabId,
    CoverItem item,
  ) {
    if (tabId == 'liked') {
      showQqTracksDialog(
        context,
        title: item.title,
        subtitle: context.l10n.trackListArtistHotSongs,
        loadTracks: (r) => r.read(qqMusicApiProvider).likedSongs(),
      );
      return;
    }
    showQqPlaylistDetailDialog(context, item);
  }

  @override
  String favTabSubtitle(
    AppLocalizations l10n,
    String tabId,
    int count,
    bool loggedIn,
  ) {
    if (!loggedIn) {
      return switch (tabId) {
        'collectedPlaylist' => l10n.pageFavKgCollectedPlaylistLoginHint,
        'liked' => l10n.pageFavKgCollectedAlbumLoginHint,
        _ => l10n.pageFavKgCreatedLoginHint,
      };
    }
    return switch (tabId) {
      'collectedPlaylist' => l10n.pageFavKgCollectedPlaylistCount(count: count),
      'liked' => l10n.pageFavKgCollectedAlbumCount(count: count),
      _ => l10n.pageFavKgCreatedCount(count: count),
    };
  }

  @override
  String favLoginDesc(AppLocalizations l10n) => l10n.pageFavLoginDesc;

  @override
  String favEmptyHint(AppLocalizations l10n) => l10n.pageFavEmptyHint;
}

// ── NK ─────────────────────────────────────────────────────────────────

class _NekoCollection extends CollectionPlatform {
  @override
  String get source => 'neko';

  @override
  String label(AppLocalizations l10n) => l10n.platformNeko;

  @override
  dynamic get authSignal =>
      nekoApiProvider.select<Object?>((s) => s.isLoggedIn);

  @override
  String likeFailedText(AppLocalizations l10n) => l10n.toastLoginRequiredNeko;

  @override
  NotifierProvider<ShellPageSelection<String>, String?> get tabSelection =>
      favoritesNekoTabProvider;

  @override
  List<String> get tabIds => const ['created', 'collectedPlaylist', 'liked'];

  @override
  bool enabled(dynamic ref) => ref.read(appPrefsProvider).nekoEnabled;

  @override
  bool loggedIn(dynamic ref) => ref.read(nekoApiProvider).isLoggedIn;

  @override
  Future<void> login(BuildContext context) => showNekoLoginDialog(context);

  @override
  String likeKey(Track t) => t.id;

  @override
  String? likedUserKey(dynamic ref) {
    final id = ref.read(nekoApiProvider).userId;
    return id.isEmpty ? null : id;
  }

  @override
  Future<Set<String>> fetchLikedIds(dynamic ref) =>
      ref.read(nekoApiProvider).likedIds();

  @override
  Future<List<Track>> fetchLikedTracks(dynamic ref) =>
      ref.read(nekoApiProvider).likedTracks();

  @override
  Future<void> setLiked(dynamic ref, Track t, bool like) =>
      ref.read(nekoApiProvider).like(t.id, like: like);

  @override
  LikedView likedView(dynamic ref) {
    final store = ref.read(likedStoreProvider);
    return LikedView(
      tracks: store.tracks(source),
      total: store.total(source),
      loaded: store.loaded(source),
      loading: store.loading(source),
      error: store.error(source),
      likeIds: ref.read(likeControllerProvider).idsFor(source),
    );
  }

  @override
  void resetLiked(dynamic ref) => ref.read(likedStoreProvider).reset(source);

  @override
  void ensureLikedLoaded(dynamic ref) {
    if (!enabled(ref) || !loggedIn(ref)) return; // 关闭/未登录不发请求
    ref.read(likedStoreProvider).ensureLoaded(source);
  }

  @override
  Future<void> likedRefresh(BuildContext context, dynamic ref) =>
      ref.read(likedStoreProvider).refresh(source, writeCache: true);

  @override
  String likedSubtitle(dynamic ref, AppLocalizations l10n, LikedView view) =>
      likedAvailable(ref)
      ? l10n.commonSongCountHint(count: view.total)
      : l10n.pageLikedNekoLoginHint;

  @override
  String likedLoginDesc(AppLocalizations l10n) => l10n.pageLikedNekoLoginDesc;

  @override
  String likedEmptyHint(AppLocalizations l10n) => l10n.pageLikedNekoEmptyHint;

  @override
  List<CollectionTab> tabs(AppLocalizations l10n) => [
    CollectionTab('created', (l) => l.pageFavKgCreated, EtaIcons.music2Outline),
    CollectionTab(
      'collectedPlaylist',
      (l) => l.pageFavKgCollectedPlaylist,
      EtaIcons.music2Outline,
    ),
    CollectionTab('liked', (l) => l.sidebarLiked, EtaIcons.music2Outline),
  ];

  @override
  String get defaultTabId => 'created';

  @override
  Future<Map<String, List<CoverItem>>> fetchFavorites(
    dynamic ref,
    String tabId,
  ) async {
    final api = ref.read(nekoApiProvider);
    final lib = await api.userLibrary();
    String? cover(String? path) {
      if (path == null || path.isEmpty || path.contains('/avatar/default')) {
        return null;
      }
      return api.resolveUrl(path);
    }

    CoverItem toItem(NekoPlaylist p) => CoverItem(
      id: p.id,
      title: p.name,
      cover: cover(p.firstMusicCover),
      subtitle: p.creator ?? '',
      trackCount: p.musicCount,
      source: 'neko',
    );

    var likedItems = const <CoverItem>[];
    try {
      final ids = await api.likedIds();
      if (ids.isNotEmpty) {
        likedItems = [
          CoverItem(
            id: 'profile:favorites',
            title: '我喜欢',
            trackCount: ids.length,
            source: 'neko',
          ),
        ];
      }
    } catch (_) {
      // 计数失败不影响歌单展示
    }
    return {
      tabKey('created'): lib.createdPlaylists.map(toItem).toList(),
      tabKey('collectedPlaylist'): lib.collectedPlaylists.map(toItem).toList(),
      tabKey('liked'): likedItems,
    };
  }

  @override
  void openFavorite(
    BuildContext context,
    dynamic ref,
    String tabId,
    CoverItem item,
  ) {
    if (tabId == 'liked') {
      showNekoTracksDialog(
        context,
        title: item.title,
        cover: item.cover,
        loadTracks: (r) => r.read(nekoApiProvider).likedTracks(),
      );
      return;
    }
    if (tabId == 'collectedPlaylist') {
      showNekoFavoritePlaylistDialog(context, item);
      return;
    }
    showNekoPlaylistDetailDialog(context, item);
  }

  @override
  String favTabSubtitle(
    AppLocalizations l10n,
    String tabId,
    int count,
    bool loggedIn,
  ) {
    if (!loggedIn) {
      return switch (tabId) {
        'collectedPlaylist' => l10n.pageFavKgCollectedPlaylistLoginHint,
        'liked' => l10n.pageFavKgCollectedAlbumLoginHint,
        _ => l10n.pageFavKgCreatedLoginHint,
      };
    }
    return switch (tabId) {
      'collectedPlaylist' => l10n.pageFavKgCollectedPlaylistCount(count: count),
      'liked' => l10n.pageFavKgCollectedAlbumCount(count: count),
      _ => l10n.pageFavKgCreatedCount(count: count),
    };
  }

  @override
  String favLoginDesc(AppLocalizations l10n) => l10n.pageFavNekoLoginDesc;

  @override
  String favEmptyHint(AppLocalizations l10n) => l10n.pageFavNekoEmptyHint;
}
