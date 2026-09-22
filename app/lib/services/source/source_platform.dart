// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 统一「音源注册表」：把**搜索 / 播放解析 / 元信息**三类能力收敛到一个
/// [SourcePlatform] 接口，UI 与播放管线只面向本文件的接口，不再出现
/// `switch (track.source)` 之类的具体平台分支。
///
/// 与既有注册表的关系（本文件是**组合者**，不替换它们）：
/// - 评论能力 → `widgets/dialogs/comment_platform.dart` 的 `CommentPlatform`；
/// - 收藏 / 我喜欢 → `widgets/dialogs/collection_platform.dart` 的 `CollectionPlatform`；
/// - 歌词能力 → `services/lyrics/engine/lyric_source.dart` 的 `LyricSource` 管线。
///
/// 每个适配器负责该源的全部差异：标签 / 启用 / 登录态、搜索、播放 URL 解析、
/// 详情弹窗，以及组合能力访问器；**新增音源 = 实现一个 [SourcePlatform] 并放进
/// [_all]**，各调用点无需改动。
///
/// 说明：注册表按 [Track.source] 取值（`netease` / `kugou` / `qqmusic` /
/// `neko` / `local` / `streaming`；不含 subsonic）。
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../stores/app_prefs.dart';
import '../../stores/providers.dart';
import '../../widgets/dialogs/collection_platform.dart';
import '../../widgets/dialogs/comment_platform.dart';
import '../../widgets/dialogs/kugou_login_button.dart';
import '../../widgets/dialogs/neko_login_dialog.dart';
import '../../widgets/dialogs/netease_login_dialog.dart';
import '../../widgets/dialogs/qqmusic_login_dialog.dart';
import '../../widgets/dialogs/track_list_dialog.dart';
import '../lyrics/engine/lyric_source.dart';
import '../lyrics/sources/kugou_lyric_source.dart';
import '../lyrics/sources/local_lyric_source.dart';
import '../lyrics/sources/neko_lyric_source.dart';
import '../lyrics/sources/netease_lyric_source.dart';
import '../lyrics/sources/qqmusic_lyric_source.dart';
import '../lyrics/sources/streaming_lyric_source.dart';
import '../netease/netease_api.dart';
import '../netease/track.dart';
import '../../utils/format.dart';
import '../streaming/streaming_client.dart';
import '../streaming/streaming_http.dart';
import '../streaming/streaming_provider.dart';
import '../streaming/streaming_quality.dart';
import '../streaming/streaming_session.dart';

/// 搜索结果的类别（专辑 / 歌手 / 歌单；歌曲单独走 [SourcePlatform.searchSongs]）。
///
/// 用公开枚举替代搜索页私有的 `_SearchTab`，让适配器无需依赖页面实现。
enum SourceSearchKind { song, album, artist, playlist }

/// 单个音源的统一适配器。
abstract class SourcePlatform {
  /// 平台标识（与 `Track.source` 对齐）。
  String get source;

  /// 平台展示名（本地化）；未知源回退为 [source] 本身。
  String label(AppLocalizations l10n) => source;

  /// 是否启用（实验源由设置开关控制；默认恒启用）。
  bool enabled(dynamic ref) => true;

  /// 是否已登录（需要登录的平台覆写；本地 / 流媒体恒 true）。
  bool loggedIn(dynamic ref) => true;

  /// 登录动作（弹对应平台登录框）。
  Future<void> login(BuildContext context) async {}

  /// 登录态信号（页面据此监听并在变化时重置/重载）。
  dynamic get authSignal => null;

  /// 是否出现在「搜索音源下拉」中（local / streaming 无搜索能力 → false）。
  bool get searchable => true;

  /// 是否参与搜索页 `'all'` 聚合。
  bool get inAggregate => true;

  /// 下载器（Rust）回退是否支持本源；QQMusic 明确不支持。
  bool get downloadFallbackSupported => true;

  /// 下载回退不支持本源时的诊断日志（仅 [downloadFallbackSupported] == false 会用到）。
  String downloadUnsupportedLog(Track t) => '下载回退不支持 $source: ${t.title}';

  // ── 搜索能力 ──────────────────────────────────────────────────────

  /// 搜索单曲。[append] 追加下一页；[loaded] 为该源已累计条数；[limit] 每页条数。
  Future<SearchResult<Track>> searchSongs(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) async => const SearchResult<Track>(items: [], total: 0, hasMore: false);

  Future<SearchResult<CoverItem>> searchAlbums(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) async => const SearchResult<CoverItem>(items: [], total: 0, hasMore: false);

  Future<SearchResult<CoverItem>> searchArtists(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) async => const SearchResult<CoverItem>(items: [], total: 0, hasMore: false);

  Future<SearchResult<CoverItem>> searchPlaylists(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) async => const SearchResult<CoverItem>(items: [], total: 0, hasMore: false);

  /// 按 [kind] 分派的封面搜索（专辑 / 歌手 / 歌单）。
  Future<SearchResult<CoverItem>> searchCover(
    dynamic ref,
    String query, {
    required SourceSearchKind kind,
    required bool append,
    required int loaded,
    required int limit,
  }) => switch (kind) {
    SourceSearchKind.album => searchAlbums(
      ref,
      query,
      append: append,
      loaded: loaded,
      limit: limit,
    ),
    SourceSearchKind.artist => searchArtists(
      ref,
      query,
      append: append,
      loaded: loaded,
      limit: limit,
    ),
    SourceSearchKind.playlist => searchPlaylists(
      ref,
      query,
      append: append,
      loaded: loaded,
      limit: limit,
    ),
    SourceSearchKind.song => throw ArgumentError(
      'searchCover 不支持歌曲类别，请用 searchSongs',
    ),
  };

  // ── 播放能力 ──────────────────────────────────────────────────────

  /// 把 [track] 按 [quality] 解析为可播放 URL；不可用 → null。
  ///
  /// [streamingQuality] 仅流媒体源使用（null = 读全局偏好）；[log] 为可选
  /// 诊断日志回调。
  Future<String?> resolvePlayUrl(
    dynamic ref,
    Track track, {
    required String quality,
    String? streamingQuality,
    void Function(String message)? log,
  });

  // ── 播放辅助（歌曲缓存 / 自动换源 / 元数据补齐） ──────────────────

  /// 是否使用磁盘歌曲缓存（NT / KG）。
  bool get songCacheable => false;

  /// 歌曲缓存键用的曲目 id（KG 用 hash；其余用 [Track.id]）。
  String songCacheId(Track t) => t.id;

  /// 歌曲缓存落盘时携带的 Referer（可空串）。
  String get songCacheReferer => '';

  /// 播放失败时是否允许自动换源（搜索另一平台同名曲重试）。
  /// local / streaming 不参与。
  bool get autoFallback => true;

  /// 自动换源的候选曲目（搜索另一平台）。[autoFallback] 为 false 时不调用。
  Future<List<Track>> fallbackCandidates(dynamic ref, Track t) async => const [];

  /// 播放前的展示元数据补齐（NK 用其它源补全）；默认原样返回。
  Future<Track> enrichMetadata(dynamic ref, Track t) async => t;

  // ── 媒体信息（右键「媒体详细信息」弹窗） ──────────────────────────

  /// 该源特有的音质描述（如 KG 品质链 + 体积）；无 → null。
  String? qualityLabel(AppLocalizations l10n, Track t) => null;

  /// 由曲目元数据估算的文件体积（如 KG 各档 sizes 的最优项）；无 → null。
  int? estimatedFileSize(Track t) => null;

  // ── 组合能力访问器 ────────────────────────────────────────────────

  /// 该源的「收藏 / 我喜欢」适配器；无收藏能力（local / streaming）→ null。
  CollectionPlatform? get collections => null;

  /// 该源的评论适配器（`CommentPlatform`，来自
  /// `widgets/dialogs/comment_platform.dart`）；无 → null。
  CommentPlatform? get comments => null;

  /// 该源对应的歌词来源（复用现有 `services/lyrics` 管线）；无 → 空列表。
  List<LyricSource> lyricSources(dynamic ref) => const [];

  // ── 详情弹窗 ──────────────────────────────────────────────────────

  /// 点击搜索结果的封面项时打开对应详情弹窗（专辑 / 歌手 / 歌单）。
  void openCover(
    BuildContext context,
    dynamic ref,
    SourceSearchKind kind,
    CoverItem item,
  ) {}
}

/// 按 `Track.source` 取适配器；未注册源回退为「未知源」（保持既有行为：
/// 播放解析返回 null 并记录「暂不支持的播放源」，标签回退为 source）。
SourcePlatform sourcePlatform(String source) =>
    _registry[source] ?? _UnknownSourcePlatform(source);

/// 已启用且可搜索的平台（顺序即搜索音源下拉顺序）。
List<SourcePlatform> sourcePlatforms(dynamic ref) => _all
    .where((p) => p.searchable && p.enabled(ref))
    .toList(growable: false);

/// 全部已注册平台（含 local / streaming；歌词管线等内部枚举用）。
List<SourcePlatform> allSourcePlatforms() => List.unmodifiable(_all);

/// 参与 `'all'` 聚合的**已启用**来源（顺序即聚合顺序）。
List<String> aggregateSources(dynamic ref) => [
  for (final p in _all)
    if (p.inAggregate && p.enabled(ref)) p.source,
];

/// 参与 `'all'` 聚合的**全部**来源（含当前被关闭的实验源；用于预置游标表键）。
List<String> aggregateSourceKeys() => [
  for (final p in _all)
    if (p.inAggregate) p.source,
];

final List<SourcePlatform> _all = [
  _NeteaseSource(),
  _KugouSource(),
  _QqSource(),
  _NekoSource(),
  _LocalSource(),
  _StreamingSource(),
];

final Map<String, SourcePlatform> _registry = {
  for (final p in _all) p.source: p,
};

/// 未注册源：保持旧行为（无法解析播放 URL、标签为 source 本身、不参与搜索）。
class _UnknownSourcePlatform extends SourcePlatform {
  _UnknownSourcePlatform(this.source);

  @override
  final String source;

  @override
  bool get searchable => false;

  @override
  bool get inAggregate => false;

  @override
  Future<String?> resolvePlayUrl(
    dynamic ref,
    Track track, {
    required String quality,
    String? streamingQuality,
    void Function(String message)? log,
  }) async {
    log?.call('暂不支持的播放源: ${track.source}（${track.title}）');
    return null;
  }
}

// ── NT ─────────────────────────────────────────────────────────────────

class _NeteaseSource extends SourcePlatform {
  @override
  String get source => 'netease';

  @override
  bool get songCacheable => true;

  @override
  String get songCacheReferer => 'https://music.163.com/';

  @override
  Future<List<Track>> fallbackCandidates(dynamic ref, Track t) async {
    final keyword = [
      t.title,
      if (t.artistNames.trim().isNotEmpty) t.artistNames.trim(),
    ].join(' ');
    return (await sourcePlatform('kugou').searchSongs(
      ref,
      keyword,
      append: false,
      loaded: 0,
      limit: 20,
    )).items;
  }

  @override
  String label(AppLocalizations l10n) => l10n.platformNetease;

  @override
  dynamic get authSignal =>
      neteaseAuthProvider.select<Object?>((a) => a?.userId);

  @override
  bool loggedIn(dynamic ref) => ref.read(neteaseAuthProvider) != null;

  @override
  Future<void> login(BuildContext context) =>
      showNeteaseLoginDialog(context);

  @override
  CollectionPlatform? get collections => collectionPlatform(source);

  @override
  CommentPlatform? get comments => commentPlatformFor(source);

  @override
  List<LyricSource> lyricSources(dynamic ref) => const [NeteaseLyricSource()];

  @override
  Future<SearchResult<Track>> searchSongs(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) => ref
      .read(neteaseApiProvider)
      .searchSongs(query, offset: append ? loaded : 0, limit: limit);

  @override
  Future<SearchResult<CoverItem>> searchAlbums(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) => ref
      .read(neteaseApiProvider)
      .searchAlbums(query, offset: append ? loaded : 0, limit: limit);

  @override
  Future<SearchResult<CoverItem>> searchArtists(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) => ref
      .read(neteaseApiProvider)
      .searchArtists(query, offset: append ? loaded : 0, limit: limit);

  @override
  Future<SearchResult<CoverItem>> searchPlaylists(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) => ref
      .read(neteaseApiProvider)
      .searchPlaylists(query, offset: append ? loaded : 0, limit: limit);

  @override
  Future<String?> resolvePlayUrl(
    dynamic ref,
    Track track, {
    required String quality,
    String? streamingQuality,
    void Function(String message)? log,
  }) => ref.read(neteaseApiProvider).resolvePlayUrl(track.id, quality: quality);

  @override
  void openCover(
    BuildContext context,
    dynamic ref,
    SourceSearchKind kind,
    CoverItem item,
  ) {
    switch (kind) {
      case SourceSearchKind.album:
        showNeteaseAlbumDialog(context, item);
      case SourceSearchKind.artist:
        showNeteaseArtistDialog(context, item);
      default:
        showPlaylistDetailDialog(context, item);
    }
  }
}

// ── KG ─────────────────────────────────────────────────────────────────

class _KugouSource extends SourcePlatform {
  @override
  String get source => 'kugou';

  @override
  bool get songCacheable => true;

  @override
  String songCacheId(Track t) => t.kugou?.hash ?? t.id;

  @override
  String get songCacheReferer => 'https://www.kugou.com/';

  @override
  Future<List<Track>> fallbackCandidates(dynamic ref, Track t) async {
    final keyword = [
      t.title,
      if (t.artistNames.trim().isNotEmpty) t.artistNames.trim(),
    ].join(' ');
    return (await sourcePlatform('netease').searchSongs(
      ref,
      keyword,
      append: false,
      loaded: 0,
      limit: 20,
    )).items;
  }

  @override
  String label(AppLocalizations l10n) => l10n.platformKugou;

  @override
  int? estimatedFileSize(Track t) {
    const order = ['flac24bit', 'flac', '320k', '128k'];
    final sizes = t.kugou?.sizes;
    if (sizes == null) return null;
    for (final q in order) {
      final s = sizes[q];
      if (s != null && s > 0) return s;
    }
    return null;
  }

  @override
  String? qualityLabel(AppLocalizations l10n, Track t) {
    final k = t.kugou;
    if (k == null) return null;
    const chain = ['hi-res', 'lossless', 'hq', 'sq', 'lq'];
    String? label;
    for (final level in chain) {
      if (k.hashFor(level) != null) {
        label = l10nQualityLabel(l10n, level);
        break;
      }
    }
    if (label == null) return null;
    final size = estimatedFileSize(t);
    return size == null ? label : '$label · ${formatBytes(size)}';
  }

  @override
  dynamic get authSignal =>
      kugouApiProvider.select<Object?>((s) => s.session?.userid);

  @override
  bool loggedIn(dynamic ref) => ref.read(kugouApiProvider).session != null;

  @override
  Future<void> login(BuildContext context) async {
    await showKugouLoginDialog(context);
  }

  @override
  CollectionPlatform? get collections => collectionPlatform(source);

  @override
  CommentPlatform? get comments => commentPlatformFor(source);

  @override
  List<LyricSource> lyricSources(dynamic ref) => const [KugouLyricSource()];

  @override
  Future<SearchResult<Track>> searchSongs(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) {
    final page = append ? (loaded ~/ limit) + 1 : 1;
    return ref
        .read(kugouApiProvider)
        .searchSongs(query, page: page, limit: limit);
  }

  Future<SearchResult<CoverItem>> _searchCover(
    dynamic ref,
    String query, {
    required String type,
    required bool append,
    required int loaded,
    required int limit,
  }) async {
    final page = append ? (loaded ~/ limit) + 1 : 1;
    final raw = await ref
        .read(kugouApiProvider)
        .searchByType(query, type: type, page: page, pagesize: limit);
    return SearchResult<CoverItem>(
      items: raw.items.whereType<CoverItem>().toList(),
      total: raw.total,
      hasMore: raw.hasMore,
    );
  }

  @override
  Future<SearchResult<CoverItem>> searchAlbums(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) => _searchCover(
    ref,
    query,
    type: 'album',
    append: append,
    loaded: loaded,
    limit: limit,
  );

  @override
  Future<SearchResult<CoverItem>> searchArtists(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) => _searchCover(
    ref,
    query,
    type: 'author',
    append: append,
    loaded: loaded,
    limit: limit,
  );

  @override
  Future<SearchResult<CoverItem>> searchPlaylists(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) => _searchCover(
    ref,
    query,
    type: 'special',
    append: append,
    loaded: loaded,
    limit: limit,
  );

  @override
  Future<String?> resolvePlayUrl(
    dynamic ref,
    Track track, {
    required String quality,
    String? streamingQuality,
    void Function(String message)? log,
  }) async {
    final info = track.kugou;
    if (info == null) {
      log?.call('缺少 KG 品质信息: ${track.title}');
      return null;
    }
    return ref.read(kugouApiProvider).resolvePlayUrl(info, quality: quality);
  }

  @override
  void openCover(
    BuildContext context,
    dynamic ref,
    SourceSearchKind kind,
    CoverItem item,
  ) {
    switch (kind) {
      case SourceSearchKind.album:
        showKugouAlbumDialog(context, item);
      case SourceSearchKind.artist:
        showKugouArtistDialog(context, item);
      default:
        showKugouPlaylistDetailDialog(context, item);
    }
  }
}

// ── QQ ─────────────────────────────────────────────────────────────────

class _QqSource extends SourcePlatform {
  @override
  String get source => 'qqmusic';

  @override
  Future<List<Track>> fallbackCandidates(dynamic ref, Track t) async {
    final keyword = [
      t.title,
      if (t.artistNames.trim().isNotEmpty) t.artistNames.trim(),
    ].join(' ');
    return (await sourcePlatform('netease').searchSongs(
      ref,
      keyword,
      append: false,
      loaded: 0,
      limit: 20,
    )).items;
  }

  @override
  String label(AppLocalizations l10n) => l10n.platformQQMusic;

  @override
  dynamic get authSignal =>
      qqMusicApiProvider.select<Object?>((s) => s.isLoggedIn);

  @override
  bool loggedIn(dynamic ref) => ref.read(qqMusicApiProvider).isLoggedIn;

  @override
  Future<void> login(BuildContext context) async {
    await showQqMusicLoginDialog(context);
  }

  @override
  bool get downloadFallbackSupported => false;

  @override
  String downloadUnsupportedLog(Track t) =>
      '下载回退不支持 QQMusic: ${t.title}';

  @override
  CollectionPlatform? get collections => collectionPlatform(source);

  @override
  CommentPlatform? get comments => commentPlatformFor(source);

  @override
  List<LyricSource> lyricSources(dynamic ref) => const [QqmusicLyricSource()];

  @override
  Future<SearchResult<Track>> searchSongs(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) {
    final page = append ? (loaded ~/ limit) + 1 : 1;
    return ref
        .read(qqMusicApiProvider)
        .searchSongs(query, page: page, limit: limit);
  }

  @override
  Future<SearchResult<CoverItem>> searchAlbums(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) {
    final page = append ? (loaded ~/ limit) + 1 : 1;
    return ref
        .read(qqMusicApiProvider)
        .searchAlbums(query, page: page, limit: limit);
  }

  @override
  Future<SearchResult<CoverItem>> searchArtists(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) {
    // QQ 歌手搜索单页上限 30（>30 服务端返回空）：分页除数跟随实际请求量，
    // 避免页号漂移。
    const size = 30;
    final page = append ? (loaded ~/ size) + 1 : 1;
    return ref
        .read(qqMusicApiProvider)
        .searchArtists(query, page: page, limit: size);
  }

  @override
  Future<SearchResult<CoverItem>> searchPlaylists(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) {
    final page = append ? (loaded ~/ limit) + 1 : 1;
    return ref
        .read(qqMusicApiProvider)
        .searchPlaylists(query, page: page, limit: limit);
  }

  @override
  Future<String?> resolvePlayUrl(
    dynamic ref,
    Track track, {
    required String quality,
    String? streamingQuality,
    void Function(String message)? log,
  }) => ref.read(qqMusicApiProvider).resolvePlayUrl(track, quality: quality);

  @override
  void openCover(
    BuildContext context,
    dynamic ref,
    SourceSearchKind kind,
    CoverItem item,
  ) {
    switch (kind) {
      case SourceSearchKind.album:
        showQqAlbumDetailDialog(context, item);
      case SourceSearchKind.artist:
        showQqArtistDetailDialog(context, item);
      default:
        showQqPlaylistDetailDialog(context, item);
    }
  }
}

// ── NK ─────────────────────────────────────────────────────────────────

class _NekoSource extends SourcePlatform {
  @override
  String get source => 'neko';

  @override
  Future<List<Track>> fallbackCandidates(dynamic ref, Track t) async {
    final keyword = [
      t.title,
      if (t.artistNames.trim().isNotEmpty) t.artistNames.trim(),
    ].join(' ');
    return (await sourcePlatform('netease').searchSongs(
      ref,
      keyword,
      append: false,
      loaded: 0,
      limit: 20,
    )).items;
  }

  @override
  Future<Track> enrichMetadata(dynamic ref, Track t) async {
    if (!enabled(ref)) return t;
    return ref.read(nekoMetadataEnricherProvider).enrich(t);
  }

  @override
  String label(AppLocalizations l10n) => l10n.platformNeko;

  @override
  bool enabled(dynamic ref) => ref.read(appPrefsProvider).nekoEnabled;

  @override
  dynamic get authSignal =>
      nekoApiProvider.select<Object?>((s) => s.isLoggedIn);

  @override
  bool loggedIn(dynamic ref) => ref.read(nekoApiProvider).isLoggedIn;

  @override
  Future<void> login(BuildContext context) async {
    await showNekoLoginDialog(context);
  }

  @override
  CollectionPlatform? get collections => collectionPlatform(source);

  @override
  CommentPlatform? get comments => commentPlatformFor(source);

  @override
  List<LyricSource> lyricSources(dynamic ref) => [NekoLyricSource(ref)];

  @override
  Future<SearchResult<Track>> searchSongs(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) {
    // 服务端无分页（上限约 50），一次给全，hasMore=false。
    return ref.read(nekoApiProvider).searchSongs(query, page: 1);
  }

  @override
  Future<SearchResult<CoverItem>> searchAlbums(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) => ref.read(nekoApiProvider).searchAlbums(query);

  @override
  Future<SearchResult<CoverItem>> searchArtists(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) => ref.read(nekoApiProvider).searchArtists(query);

  @override
  Future<SearchResult<CoverItem>> searchPlaylists(
    dynamic ref,
    String query, {
    required bool append,
    required int loaded,
    required int limit,
  }) => ref.read(nekoApiProvider).searchPlaylists(query);

  @override
  Future<String?> resolvePlayUrl(
    dynamic ref,
    Track track, {
    required String quality,
    String? streamingQuality,
    void Function(String message)? log,
  }) => ref.read(nekoApiProvider).resolvePlayUrl(track, quality: quality);

  @override
  void openCover(
    BuildContext context,
    dynamic ref,
    SourceSearchKind kind,
    CoverItem item,
  ) {
    switch (kind) {
      case SourceSearchKind.playlist:
        showNekoPlaylistDetailDialog(context, item);
      case SourceSearchKind.artist:
        showNekoArtistDialog(context, item);
      default:
        break;
    }
  }
}

// ── 本地文件 ────────────────────────────────────────────────────────────

class _LocalSource extends SourcePlatform {
  @override
  String get source => 'local';

  @override
  String label(AppLocalizations l10n) => l10n.trackSourceLocal;

  @override
  bool get autoFallback => false;

  @override
  bool get searchable => false;

  @override
  bool get inAggregate => false;

  @override
  List<LyricSource> lyricSources(dynamic ref) => const [LocalLyricSource()];

  @override
  Future<String?> resolvePlayUrl(
    dynamic ref,
    Track track, {
    required String quality,
    String? streamingQuality,
    void Function(String message)? log,
  }) async {
    final p = track.localPath;
    if (p == null || p.isEmpty) {
      log?.call('缺少本地文件路径: ${track.title}');
      return null;
    }
    return p;
  }
}

// ── 流媒体（Subsonic / Jellyfin 等，不含 subsonic 独立源） ────────────────

class _StreamingSource extends SourcePlatform {
  @override
  String get source => 'streaming';

  @override
  String label(AppLocalizations l10n) => l10n.trackSourceStreaming;

  @override
  bool get autoFallback => false;

  @override
  bool get searchable => false;

  @override
  bool get inAggregate => false;

  @override
  List<LyricSource> lyricSources(dynamic ref) => [StreamingLyricSource(ref)];

  @override
  Future<String?> resolvePlayUrl(
    dynamic ref,
    Track track, {
    required String quality,
    String? streamingQuality,
    void Function(String message)? log,
  }) async {
    final serverId = track.serverId;
    final originalId = track.originalId;
    if (serverId == null || originalId == null || originalId.isEmpty) {
      log?.call('流媒体曲目缺少 serverId/originalId: ${track.title}');
      return null;
    }
    final cfg = ref.read(streamingProvider.notifier).serverConfigById(serverId);
    if (cfg == null) {
      log?.call('流媒体服务器不存在: $serverId（${track.title}）');
      return null;
    }
    final sq =
        streamingQuality ?? ref.read(appPrefsProvider).streamingQuality;
    final client = StreamingClient(cfg);
    final url = await client.getStreamUrl(
      originalId,
      playSessionId: sessionIdForTrack(track.id),
      streamingQuality: sq,
    );
    if (streamingTranscodeFor(sq).isOriginal) return url;
    // 兼容性：部分服务端未启用转码，会以 HTTP 200 + JSON 错误响应（Navidrome 实测）。
    // 探测一次；不可用则该服务器记入缓存并回退原文件，避免每次播放都拿到坏 URL。
    final usable = await _streamTranscodeUsable(cfg.id, url);
    if (usable) return url;
    log?.call('流媒体服务端未启用转码，回退原文件: ${track.title}');
    return client.getStreamUrl(
      originalId,
      playSessionId: sessionIdForTrack(track.id),
      streamingQuality: 'original',
    );
  }
}

/// 流媒体服务端是否支持转码（按 serverId 缓存；失败只探测一次，避免重复坏 URL）。
final Map<String, bool> _streamTranscodeSupport = <String, bool>{};

Future<bool> _streamTranscodeUsable(String serverId, String url) async {
  final known = _streamTranscodeSupport[serverId];
  if (known != null) return known;
  final ok = await _probeAudioUrl(url);
  _streamTranscodeSupport[serverId] = ok;
  return ok;
}

/// 轻量探测 URL 是否返回音频：Range 取前 64B。
/// 常见失败形态：服务端未启用转码 → `HTTP 200 application/json`（Navidrome 实测）。
Future<bool> _probeAudioUrl(String url) async {
  try {
    final res = await fetchWithTimeout(
      url,
      headers: const {'Range': 'bytes=0-63'},
      timeout: const Duration(seconds: 10),
    );
    if (res.statusCode >= 400) return false;
    final buf = BytesBuilder(copy: false);
    await for (final chunk in res) {
      buf.add(chunk);
      if (buf.length >= 64) break;
    }
    final ct = res.headers.contentType?.mimeType.toLowerCase() ?? '';
    if (ct.startsWith('audio/') || ct == 'application/octet-stream') return true;
    return _looksLikeAudio(buf.takeBytes());
  } catch (_) {
    return false;
  }
}

bool _looksLikeAudio(List<int> b) {
  if (b.length < 4) return false;
  if (b[0] == 0x66 && b[1] == 0x4C && b[2] == 0x61 && b[3] == 0x43) {
    return true; // fLaC
  }
  if (b[0] == 0x4F && b[1] == 0x67 && b[2] == 0x67 && b[3] == 0x53) {
    return true; // OggS
  }
  if (b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) return true; // ID3v2
  if (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) return true; // MPEG frame sync
  if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46) {
    return true; // RIFF
  }
  return false;
}
