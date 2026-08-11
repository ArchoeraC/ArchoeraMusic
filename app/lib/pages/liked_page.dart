import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/netease/track.dart';
import '../services/playback/playback_notifier.dart';
import '../stores/providers.dart';
import '../../l10n/l10n.dart';
import '../widgets/dialogs/kugou_login_button.dart';
import '../widgets/dialogs/netease_login_dialog.dart';
import '../widgets/common/login_guide.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/list/song_list.dart';
import '../widgets/common/toast.dart';
import '../widgets/dialogs/track_context_menu.dart';

/// 我喜欢页（对齐原项目 Liked.vue）。
///
/// 平台切换（网易云 / 酷狗）：登录对应平台后拉取「红心收藏」/ 酷狗
/// 「我喜欢」歌单 → SongList 可播放。未登录显示对应平台登录引导。
class LikedPage extends ConsumerStatefulWidget {
  const LikedPage({super.key});

  @override
  ConsumerState<LikedPage> createState() => _LikedPageState();
}

class _LikedPageState extends ConsumerState<LikedPage> {
  List<Track> _tracks = const [];
  bool _loading = false;
  bool _loaded = false;
  String _error = '';
  String _platform = 'netease';
  bool _resolving = false;

  bool get _neteaseLoggedIn => ref.read(neteaseAuthProvider) != null;
  bool get _kugouLoggedIn => ref.read(kugouApiProvider).session != null;

  @override
  void initState() {
    super.initState();
    // 默认选已登录平台（网易云优先）；都未登录保持网易云引导
    if (!_neteaseLoggedIn && _kugouLoggedIn) _platform = 'kugou';
    if (_platform == 'kugou' ? _kugouLoggedIn : _neteaseLoggedIn) {
      _fetch();
    }
  }

  void _switchPlatform(String platform) {
    if (platform == _platform) return;
    setState(() {
      _platform = platform;
      _tracks = const [];
      _loaded = false;
      _error = '';
    });
    if (platform == 'kugou' ? _kugouLoggedIn : _neteaseLoggedIn) {
      _fetch();
    }
  }

  /// 登录态变化（登录成功 / 退出）时刷新当前平台列表。
  void _onAuthChanged() {
    final logged = _platform == 'kugou' ? _kugouLoggedIn : _neteaseLoggedIn;
    setState(() {
      _tracks = const [];
      _loaded = false;
      _error = '';
    });
    if (logged) _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final List<Track> tracks;
      if (_platform == 'kugou') {
        tracks = await ref.read(kugouApiProvider).likedTracks();
      } else {
        final account = ref.read(neteaseAuthProvider);
        if (account == null) {
          setState(() {
            _loading = false;
            _loaded = true;
          });
          return;
        }
        tracks = await ref.read(neteaseApiProvider).likedSongs(account.userId);
      }
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _loaded = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loaded = true;
        _loading = false;
      });
    }
  }

  void _toast(String msg) => toast(msg);

  /// 播放全部（当前平台「我喜欢」全量作为播放队列；网易云/酷狗分开）。
  Future<void> _playAll() async {
    if (_tracks.isEmpty) return;
    try {
      await ref.read(playbackProvider.notifier).playQueue(_tracks);
      if (!mounted) return;
      _toast(context.l10n.toastPlayedAll(_tracks.length));
    } catch (_) {
      // 错误已记入播放日志
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
      await ref.read(playbackProvider.notifier).playNow(track, resolvedUrl: url);
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
      _toast(_platform == 'kugou'
          ? l10n.toastLoginRequiredKugou
          : l10n.toastLoginRequiredNetease);
      return;
    }
    // 取消喜欢 → 从平台红心列表移除该行
    if (!controller.isLiked(track)) {
      setState(() {
        _tracks = _tracks
            .where((t) => !(t.source == track.source && t.id == track.id))
            .toList();
      });
    }
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
          _toast(_platform == 'kugou'
              ? l10n.toastLoginRequiredKugou
              : l10n.toastLoginRequiredNetease);
          return;
        }
        if (!controller.isLiked(t)) {
          setState(() {
            _tracks = _tracks
                .where((x) => !(x.source == t.source && x.id == t.id))
                .toList();
          });
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
    // 登录态变化（含酷狗）时刷新列表
    ref.listen(neteaseAuthProvider, (_, next) => _onAuthChanged());
    ref.listen(kugouApiProvider, (_, next) => _onAuthChanged());

    final logged = _platform == 'kugou' ? _kugouLoggedIn : _neteaseLoggedIn;
    final subtitle = !logged
        ? (_platform == 'kugou' ? l10n.pageLikedKugouLoginHint : l10n.pageLikedNeteaseLoginHint)
        : l10n.commonSongCountHint(_tracks.length);

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
                          color: scheme.onSurfaceVariant
                              .withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (logged && _loaded && _tracks.isNotEmpty) ...[
                  SButton(
                    label: l10n.commonPlayAll,
                    icon: Icons.play_arrow_rounded,
                    variant: SButtonVariant.primary,
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
                if (logged && _loaded && _tracks.isNotEmpty)
                  SButton(
                    label: l10n.commonRefresh,
                    icon: Icons.refresh,
                    variant: SButtonVariant.secondary,
                    onPressed: _fetch,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          // ── 内容区状态机 ─────────────────────────────────────
          Expanded(
            child: !logged
                ? LoginGuide(
                    icon: Icons.favorite_outline,
                    title: l10n.pageLikedLoginTitle,
                    description: _platform == 'kugou'
                        ? l10n.pageLikedKugouLoginDesc
                        : l10n.pageLikedNeteaseLoginDesc,
                    onLogin: () async {
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
                : _loading && !_loaded
                ? const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  )
                : _error.isNotEmpty && !_loaded
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline,
                            size: 48, color: scheme.error),
                        const SizedBox(height: 10),
                        Text(l10n.pageLikedLoadFailed, style: theme.textTheme.bodyMedium),
                        const SizedBox(height: 4),
                        Text(
                          _error,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 14),
                        SButton(
                          label: l10n.commonRetry,
                          icon: Icons.refresh,
                          variant: SButtonVariant.secondary,
                          onPressed: _fetch,
                        ),
                      ],
                    ),
                  )
                : _tracks.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.favorite_border,
                          size: 48,
                          color: scheme.onSurfaceVariant
                              .withValues(alpha: 0.5),
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
                    items: _tracks,
                    playingId: playingId,
                    isPlaying: isPlaying,
                    onPlay: _playTrack,
                    onContextMenu: _onTrackMenu,
                    likedIds:
                        ref.watch(likeControllerProvider).idsFor(_platform),
                    onToggleLike: _toggleLike,
                  ),
          ),
        ],
      ),
    );
  }
}

