import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/liked/liked_loader.dart';
import '../services/netease/track.dart';
import '../services/playback/playback_notifier.dart';
import '../stores/providers.dart';
import '../../l10n/l10n.dart';
import '../widgets/dialogs/kugou_login_button.dart';
import '../widgets/dialogs/netease_login_dialog.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/streaming/empty_state.dart';
import '../widgets/list/song_list.dart';
import '../widgets/common/toast.dart';
import '../widgets/dialogs/track_context_menu.dart';

/// 我喜欢页（对齐原项目 Liked.vue）。
///
/// 平台切换（网易云 / 酷狗）：登录对应平台后拉取「红心收藏」/ 酷狗
/// 「我喜欢」歌单 → SongList 可播放。未登录显示对应平台登录引导。
///
/// 数据加载走全局 [LikedStore]（likedStoreProvider，单一数据源）：
/// - SQLite 缓存秒开（进页面先渲染已缓存全量；读写均在后台 isolate，
///   不阻塞 UI）；
/// - SWR 后台刷新全量（酷狗 / 网易云循环翻页拉满）替换上屏；
/// - 酷狗红心集合由该全量派生（LikeController 不再独立拉取）；
/// - 无分页：列表一次持有全量 Track（元数据轻量），播放全部天然全量。
class LikedPage extends ConsumerStatefulWidget {
  const LikedPage({super.key});

  @override
  ConsumerState<LikedPage> createState() => _LikedPageState();
}

class _LikedPageState extends ConsumerState<LikedPage> {
  String _platform = 'netease';
  bool _resolving = false;

  bool get _neteaseLoggedIn => ref.read(neteaseAuthProvider) != null;
  bool get _kugouLoggedIn => ref.read(kugouApiProvider).session != null;

  /// 当前平台是否已登录（内容区据此显示数据或登录引导）。
  bool get _loggedIn =>
      _platform == 'kugou' ? _kugouLoggedIn : _neteaseLoggedIn;

  @override
  void initState() {
    super.initState();
    // 默认选已登录平台（网易云优先）；都未登录保持网易云引导
    if (!_neteaseLoggedIn && _kugouLoggedIn) _platform = 'kugou';
    if (_loggedIn) _ensureLoaded(_platform);
  }

  LikedStore get _store => ref.read(likedStoreProvider);

  void _ensureLoaded(String platform) {
    _store.ensureLoaded(platform);
  }

  void _switchPlatform(String platform) {
    if (platform == _platform) return;
    setState(() => _platform = platform);
    if (_loggedIn) _ensureLoaded(platform);
  }

  /// 登录态变化（登录成功 / 退出）时刷新对应平台列表。
  void _onAuthChanged(String platform) {
    final store = _store;
    store.reset(platform);
    final logged = platform == 'kugou' ? _kugouLoggedIn : _neteaseLoggedIn;
    if (logged) store.ensureLoaded(platform);
  }

  void _toast(String msg) => toast(msg);

  /// 播放全部：直接用列表已全量加载的 tracks 作为播放队列（酷狗/网易云
  /// 均已在 store 全量拉取，无需重复请求）。
  Future<void> _playAll() async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      final tracks = _store.tracks(_platform);
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

  /// 行内红心切换（取消喜欢即从列表移除；对齐 SPlayer-Next 红心语义）。
  Future<void> _toggleLike(Track track) async {
    final l10n = context.l10n;
    final controller = ref.read(likeControllerProvider);
    final ok = await controller.toggle(track);
    if (!mounted) return;
    if (!ok) {
      _toast(
        _platform == 'kugou'
            ? l10n.toastLoginRequiredKugou
            : l10n.toastLoginRequiredNetease,
      );
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
        final l10n = context.l10n;
        final controller = ref.read(likeControllerProvider);
        final ok = await controller.toggle(t);
        if (!mounted) return;
        if (!ok) {
          _toast(
            _platform == 'kugou'
                ? l10n.toastLoginRequiredKugou
                : l10n.toastLoginRequiredNetease,
          );
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    // 选择性订阅（播放位置/FFT 50ms 更新不重建列表）
    final playingId = ref.watch(playbackProvider.select((s) => s.trackId));
    final isPlaying = ref.watch(playbackProvider.select((s) => s.playing));
    // 登录态变化时刷新对应平台列表（neteaseAuthProvider 的 state 即登录态，
    // 仅登录/登出变化；酷狗 ChangeNotifier 会因头像刷新等任意 notify，
    // 故只监听 userid 实际变化，避免每次 notify 全量重拉）
    ref.listen(neteaseAuthProvider, (prev, next) {
      _onAuthChanged('netease');
    });
    ref.listen(
      kugouApiProvider.select((s) => s.session?.userid),
      (prev, next) {
        if (prev != next) _onAuthChanged('kugou');
      },
    );

    final store = ref.watch(likedStoreProvider);
    final subtitle = !_loggedIn
        ? (_platform == 'kugou'
              ? l10n.pageLikedKugouLoginHint
              : l10n.pageLikedNeteaseLoginHint)
        : l10n.commonSongCountHint(store.total(_platform));

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
                    store.loaded(_platform) &&
                    store.tracks(_platform).isNotEmpty) ...[
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
                  ],
                  selected: _platform,
                  onChanged: _switchPlatform,
                ),
                const SizedBox(width: 12),
                if (_loggedIn &&
                    store.loaded(_platform) &&
                    store.tracks(_platform).isNotEmpty)
                  SButton(
                    label: l10n.commonRefresh,
                    icon: Icons.refresh,
                    variant: SButtonVariant.secondary,
                    onPressed: () => store.refresh(_platform, writeCache: true),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          // ── 内容区状态机（订阅全局 store，薄 UI） ─────────────
          Expanded(
            child: !_loggedIn
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
                : store.loading(_platform) && !store.loaded(_platform)
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
                          onPressed: () => store.refresh(_platform, writeCache: true),
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
                    likedIds: ref.watch(likeControllerProvider).idsFor(_platform),
                    onToggleLike: _toggleLike,
                  ),
          ),
        ],
      ),
    );
  }
}
