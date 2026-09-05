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
  bool get _loggedIn =>
      _requiresLogin
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
      platform == _qqPlatform
          ? _qqStore.tracks
          : _store.tracks(platform);

  void _ensureLoaded(String platform) {
    if (platform == _qqPlatform) {
      _qqStore.ensureLoaded();
      // 已登录 QQ：后台并入在线「我喜欢」（add-only，静默失败不影响本机）
      if (kQqFavExperimental && ref.read(qqMusicApiProvider).isLoggedIn) {
        unawaited(_mergeQqOnlineQuiet());
      }
    } else {
      _store.ensureLoaded(platform);
    }
  }

  /// 后台静默并入在线「我喜欢」（实验接口；失败不打扰，本机红心不受影响）。
  Future<void> _mergeQqOnlineQuiet() async {
    try {
      final online = await ref.read(qqMusicApiProvider).likedSongs();
      await _qqStore.mergeOnline(online);
    } catch (_) {
      // 静默（页内右上角「同步在线收藏」按钮提供显式重试与提示）
    }
  }

  void _switchPlatform(String platform) {
    if (platform == _platform) return;
    setState(() => _platform = platform);
    if (_loggedIn) _ensureLoaded(platform);
  }

  /// 登录态变化（登录成功 / 退出）时刷新对应平台列表（QQ：本机列表不清，
  /// 在线并入由 bootstrap QQ 登录监听负责，此处仅刷新 UI 状态）。
  void _onAuthChanged(String platform) {
    if (platform == _qqPlatform) {
      setState(() {});
      return;
    }
    final store = _store;
    store.reset(platform);
    final logged = platform == 'kugou' ? _kugouLoggedIn : _neteaseLoggedIn;
    if (logged) store.ensureLoaded(platform);
  }

  void _toast(String msg) => toast(msg);

  /// 播放全部：直接用已全量加载的列表作为播放队列。
  Future<void> _playAll() async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      final tracks = _tracks(_platform);
      if (tracks.isEmpty) return;
      await ref.read(playbackProvider.notifier).playQueue(tracks);
      if (!mounted) return;
      _toast(context.l10n.toastPlayedAll(tracks.length));
    } catch (e) {
      if (mounted) _toast(context.l10n.trackListPlaySourceFailed('$e'));
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _playTrack(Track track) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      final String? url;
      if (track.source == 'kugou' && track.kugou != null) {
        url = await ref.read(kugouApiProvider).resolvePlayUrl(track.kugou!);
      } else if (track.source == 'netease') {
        url = await ref.read(neteaseApiProvider).resolvePlayUrl(track.id);
      } else if (track.source == 'qqmusic') {
        url = await ref.read(qqMusicApiProvider).resolvePlayUrl(track);
      } else {
        url = null;
      }
      if (!mounted) return;
      if (url == null || url.isEmpty) {
        _toast(context.l10n.trackListNoPlayableSource);
        return;
      }
      await ref
          .read(playbackProvider.notifier)
          .playNow(track, resolvedUrl: url);
    } catch (e) {
      if (mounted) _toast(context.l10n.trackListPlaySourceFailed('$e'));
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  /// 红心失败提示（各平台独立文案；QQ 在线同步失败为实验接口可读错误）。
  String _likeFailText(String source) {
    final l10n = context.l10n;
    return switch (source) {
      'kugou' => l10n.toastLoginRequiredKugou,
      'qqmusic' => l10n.toastQqLikeSyncFailed,
      _ => l10n.toastLoginRequiredNetease,
    };
  }

  /// 行内红心切换（取消喜欢即从列表移除；对齐 SPlayer-Next 红心语义）。
  Future<void> _toggleLike(Track track) async {
    final controller = ref.read(likeControllerProvider);
    final ok = await controller.toggle(track);
    if (!mounted) return;
    if (!ok) {
      _toast(_likeFailText(track.source));
      return;
    }
    // 取消喜欢 → 列表移除 + 写库由 LikeController 统一维护
  }

  /// 行右键菜单（通用在线曲目菜单；取消收藏时从列表移除该行）。
  void _onTrackMenu(Track track, Offset global) {
    showTrackContextMenu(
      context,
      ref: ref,
      track: track,
      position: global,
      onPlay: () => _playTrack(track),
      onToggleLike: (t) async {
        final ok = await ref.read(likeControllerProvider).toggle(t);
        if (!mounted) return;
        if (!ok) {
          _toast(_likeFailText(t.source));
        }
      },
    );
  }

  /// 手动同步 QQ 在线「我喜欢」（实验接口）：在线并入本机，失败仅提示。
  Future<void> _refreshQqOnline() async {
    final l10n = context.l10n;
    if (!kQqFavExperimental) {
      _toast(l10n.toastQqLikeSyncFailed);
      return;
    }
    if (!_qqLoggedIn) {
      final ok = await showQqMusicLoginDialog(context);
      if (ok != true || !mounted) return;
    }
    try {
      final online = await ref.read(qqMusicApiProvider).likedSongs();
      final n = await _qqStore.mergeOnline(online);
      if (!mounted) return;
      _toast(
        n > 0
            ? l10n.pageLikedQqSynced(n)
            : l10n.pageLikedQqSyncedNone,
      );
    } catch (e) {
      if (!mounted) return;
      _toast(l10n.toastQqLikeSyncFailed);
    }
  }

  void _showQqLogin() {
    showQqMusicLoginDialog(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    // 选择性订阅（播放位置/FFT 50ms 更新不重建列表）
    final playingId = ref.watch(playbackProvider.select((s) => s.trackId));
    final isPlaying = ref.watch(playbackProvider.select((s) => s.playing));
    // 登录态变化时刷新对应平台列表
    ref.listen(neteaseAuthProvider, (prev, next) {
      _onAuthChanged('netease');
    });
    ref.listen(
      kugouApiProvider.select((s) => s.session?.userid),
      (prev, next) {
        if (prev != next) _onAuthChanged('kugou');
      },
    );
    ref.listen(
      qqMusicApiProvider.select((s) => s.isLoggedIn),
      (prev, next) {
        if (prev != next) _onAuthChanged(_qqPlatform);
      },
    );

    final neteaseStore = ref.watch(likedStoreProvider);
    final qqStore = ref.watch(qqLikedStoreProvider);
    final store = _platform == _qqPlatform ? null : neteaseStore;
    final qq = _platform == _qqPlatform;

    final qqTracks = qqStore.tracks;
    final qqLoaded = qqStore.loaded;
    final qqLoading = qqStore.loading && !qqLoaded;
    final qqError = qqStore.error;

    final subtitle = !_loggedIn
        ? (qq
              ? ''
              : (_platform == 'kugou'
                    ? l10n.pageLikedKugouLoginHint
                    : l10n.pageLikedNeteaseLoginHint))
        : qq
        ? (qqTracks.isEmpty
              ? l10n.pageLikedQqHint
              : l10n.commonSongCountHint(qqTracks.length))
        : l10n.commonSongCountHint(store!.total(_platform));

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 标题 ─────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.sidebarLiked,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant.withValues(
                            alpha: 0.75,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (_loggedIn &&
                    (qq
                        ? qqLoaded && qqTracks.isNotEmpty
                        : store!.loaded(_platform) &&
                            store.tracks(_platform).isNotEmpty)) ...[
                  SButton(
                    label: l10n.commonPlayAll,
                    icon: Icons.play_arrow_rounded,
                    variant: SButtonVariant.primary,
                    loading: _resolving,
                    onPressed: _playAll,
                  ),
                  const SizedBox(width: 12),
                ],
                // 平台切换
                SSegmented<String>(
                  options: [
                    SSegmentedOption('netease', l10n.platformNetease),
                    SSegmentedOption('kugou', l10n.platformKugou),
                    SSegmentedOption('qqmusic', l10n.platformQQMusic),
                  ],
                  selected: _platform,
                  onChanged: _switchPlatform,
                ),
                const SizedBox(width: 12),
                if (_loggedIn &&
                    (qq
                        ? qqLoaded &&
                            (qqTracks.isNotEmpty || _qqLoggedIn)
                        : store!.loaded(_platform) &&
                            store.tracks(_platform).isNotEmpty))
                  SButton(
                    label: qq ? l10n.pageLikedQqSyncOnline : l10n.commonRefresh,
                    icon: Icons.sync,
                    variant: SButtonVariant.secondary,
                    onPressed: qq ? _refreshQqOnline : () {
                      neteaseStore.refresh(_platform, writeCache: true);
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          // ── 内容区状态机（订阅全局 store，薄 UI） ─────────────
          Expanded(
            child: qq
                ? qqLoading
                      ? const Center(
                          child: SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                        )
                      : qqError.isNotEmpty && qqTracks.isEmpty
                      ? _ErrorState(
                          message: qqError,
                          onRetry: () => _qqStore.ensureLoaded(),
                        )
                      : qqTracks.isEmpty
                      ? _QqEmptyState(
                          loggedIn: _qqLoggedIn,
                          l10n: l10n,
                          scheme: scheme,
                          theme: theme,
                          onLogin: _showQqLogin,
                          onSync: _refreshQqOnline,
                        )
                      : SongList(
                          items: qqTracks,
                          playingId: playingId,
                          isPlaying: isPlaying,
                          onPlay: _playTrack,
                          onContextMenu: _onTrackMenu,
                          likedIds: ref
                              .watch(likeControllerProvider)
                              .idsFor(_qqPlatform),
                          onToggleLike: _toggleLike,
                        )
                : !_loggedIn
                ? StreamingEmptyState(
                    icon: Icons.favorite_outline,
                    title: l10n.pageLikedLoginTitle,
                    subtitle: _platform == 'kugou'
                        ? l10n.pageLikedKugouLoginDesc
                        : l10n.pageLikedNeteaseLoginDesc,
                    buttonLabel: l10n.navHeaderQrLogin,
                    buttonIcon: Icons.qr_code_2,
                    onButton: () async {
                      if (_platform == 'kugou') {
                        await showDialog<bool>(
                          context: context,
                          barrierColor: Colors.black.withValues(alpha: 0.5),
                          barrierDismissible: false,
                          builder: (_) => const KgQrLoginDialog(),
                        );
                      } else {
                        showNeteaseLoginDialog(context);
                      }
                    },
                  )
                : store!.loading(_platform) && !store.loaded(_platform)
                ? const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  )
                : store.error(_platform).isNotEmpty && !store.loaded(_platform)
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 48,
                          color: scheme.error,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          l10n.pageLikedLoadFailed,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          store.error(_platform),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 14),
                        SButton(
                          label: l10n.commonRetry,
                          icon: Icons.refresh,
                          variant: SButtonVariant.secondary,
                          onPressed: () =>
                              store.refresh(_platform, writeCache: true),
                        ),
                      ],
                    ),
                  )
                : store.tracks(_platform).isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.favorite_border,
                          size: 48,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          l10n.pageLikedEmpty,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _platform == 'kugou'
                              ? l10n.pageLikedKugouEmptyHint
                              : l10n.pageLikedNeteaseEmptyHint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                : SongList(
                    items: store.tracks(_platform),
                    playingId: playingId,
                    isPlaying: isPlaying,
                    onPlay: _playTrack,
                    onContextMenu: _onTrackMenu,
                    likedIds: ref
                        .watch(likeControllerProvider)
                        .idsFor(_platform),
                    onToggleLike: _toggleLike,
                  ),
          ),
        ],
      ),
    );
  }
}

/// QQ「我喜欢」空态：本机红心说明 + （可选）登录同步在线收藏入口。
class _QqEmptyState extends StatelessWidget {
  const _QqEmptyState({
    required this.loggedIn,
    required this.l10n,
    required this.scheme,
    required this.theme,
    required this.onLogin,
    required this.onSync,
  });

  final bool loggedIn;
  final AppLocalizations l10n;
  final ColorScheme scheme;
  final ThemeData theme;
  final VoidCallback onLogin;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.favorite_border,
            size: 48,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 10),
          Text(l10n.pageLikedQqEmptyTitle, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              l10n.pageLikedQqEmptyHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (!loggedIn)
            SButton(
              label: l10n.pageLikedQqLoginSync,
              icon: Icons.qr_code_2,
              variant: SButtonVariant.secondary,
              onPressed: onLogin,
            )
          else
            SButton(
              label: l10n.pageLikedQqSyncOnline,
              icon: Icons.sync,
              variant: SButtonVariant.secondary,
              onPressed: onSync,
            ),
        ],
      ),
    );
  }
}

/// QQ「我喜欢」加载错误态（本机文件损坏等罕见场景；重试）。
class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 48, color: scheme.error),
          const SizedBox(height: 10),
          Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          SButton(
            label: context.l10n.commonRetry,
            icon: Icons.refresh,
            variant: SButtonVariant.secondary,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}
