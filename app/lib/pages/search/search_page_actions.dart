// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: invalid_use_of_protected_member

part of '../search_page.dart';

extension _SearchPageActions on _SearchPageState {
  void _onTabChanged() {
    if (!_tabs.indexIsChanging) return;
    // 切换 tab：未拉过则按需请求（对齐 Search.vue watch activeTab）
    if (_query.isNotEmpty && !_currentState.loaded) {
      unawaited(_fetch(append: false));
    }
    setState(() {});
  }

  /// 切换搜索平台（'netease' / 'kugou' / 'qqmusic' 单平台；'all' 三方
  /// 并行合并——songs 与 albums/artists/playlists 各 tab 均聚合）。
  void _switchPlatform(String platform) {
    if (platform == _platform) return;
    setState(() => _platform = platform);
    _resetAll();
    if (_query.isNotEmpty) unawaited(_fetch(append: false));
  }

  /// 错误态（SearchErrorState / 聚合全败）的重试入口：QQ 失败后先退避，
  /// 避免连打把风控阈值刷得更高。
  void _retryFromError() {
    final qqInvolved = _platform == 'qqmusic' || _platform == 'all';
    if (qqInvolved && _sourceCooldown.cooling('qqmusic')) {
      _toast(context.l10n.searchWaitRetry);
      return;
    }
    unawaited(_fetch(append: false));
  }

  /// 单来源失败的说明文案：QQ 走本地化分类；其余平台保留原始异常。
  String _failureDetail(String source, Object? err) {
    if (source == 'qqmusic' && err is QqApiException) {
      return _qqFailureText(err);
    }
    return '$err';
  }

  /// QQ 失败文案映射：风控 → 带内码提示；网络 → 网络提示；业务码 → 带码。
  String _qqFailureText(QqApiException e) {
    final l = context.l10n;
    final kind = e.kind;
    if (kind == QmErrorKind.risk) return l.searchQqRiskDetail(e.code ?? 0);
    if (kind == QmErrorKind.transient) return l.searchNetworkError;
    if (kind == QmErrorKind.code) {
      return l.searchPlatformError('${e.code ?? '?'}');
    }
    return e.message;
  }

  /// 平台显示名（横幅「{source}」用）。
  String _platformLabel(String source) {
    final l = context.l10n;
    return switch (source) {
      'netease' => l.platformNetease,
      'kugou' => l.platformKugou,
      'qqmusic' => l.platformQQMusic,
      _ => source,
    };
  }

  /// 点击歌曲：解析播放 URL → 后台完整转码播放（不阻塞 UI）。
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
      if (url == null) {
        _toast(context.l10n.trackListNoPlayableSource);
        return;
      }
      _toast(context.l10n.pageSearchLoadingTrack(track.title));
      // 完整转码在后台执行，await 会阻塞到转码完成，故不等待
      unawaited(_loadUrl(url, track));
    } catch (e) {
      if (mounted) _toast(context.l10n.trackListPlaySourceFailed('$e'));
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _loadUrl(String url, Track track) async {
    try {
      // 插入当前播放之后并播放（队列/切歌可用）
      await ref
          .read(playbackProvider.notifier)
          .playNow(track, resolvedUrl: url);
    } catch (_) {
      // 错误已记入播放日志
    }
  }

  void _toast(String message) => toast(message);

  /// 专辑 / 歌手 / 歌单点击（按平台分发详情弹窗）。
  ///
  /// 聚合（'all'）下结果混三方平台，按 **CoverItem.source** 分发到对应
  /// 平台详情弹窗（NT歌单/专辑/歌手、KG、QQ 均已接通曲目列表）。
  void _onCoverTap(CoverItem item) {
    final src = _platform == 'all' ? item.source : _platform;
    if (src == 'kugou') {
      _openKugouCover(item);
      return;
    }
    if (src == 'qqmusic') {
      _openQqCover(item);
      return;
    }
    _openNeteaseCover(item);
  }

  void _openNeteaseCover(CoverItem item) {
    switch (_tab) {
      case _SearchTab.playlists:
        showPlaylistDetailDialog(context, item);
      case _SearchTab.albums:
        showNeteaseAlbumDialog(context, item);
      case _SearchTab.artists:
        showNeteaseArtistDialog(context, item);
      default:
        break;
    }
  }

  void _openKugouCover(CoverItem item) {
    switch (_tab) {
      case _SearchTab.playlists:
        showKugouPlaylistDetailDialog(context, item);
      case _SearchTab.albums:
        showKugouAlbumDialog(context, item);
      case _SearchTab.artists:
        showKugouArtistDialog(context, item);
      default:
        break;
    }
  }

  void _openQqCover(CoverItem item) {
    switch (_tab) {
      case _SearchTab.playlists:
        showQqPlaylistDetailDialog(context, item);
      case _SearchTab.albums:
        showQqAlbumDetailDialog(context, item);
      case _SearchTab.artists:
        showQqArtistDetailDialog(context, item);
      default:
        break;
    }
  }

  /// 歌曲右键菜单（通用在线曲目菜单 + 页内歌手占位）。
  void _onTrackMenu(Track track, Offset global) {
    showTrackContextMenu(
      context,
      ref: ref,
      track: track,
      position: global,
      onPlay: () => _playTrack(track),
      extra: [
        SContextMenuItem(
          label: context.l10n.menuViewArtist,
          icon: Icons.person_outline,
          onTap: () => _toast(context.l10n.pageSearchArtistComingSoon),
        ),
      ],
    );
  }

  /// 红心失败提示（各平台独立文案；QQ 在线同步失败提示实验接口可读错误）。
  String _likeFailText(String source) {
    final l10n = context.l10n;
    return switch (source) {
      'kugou' => l10n.toastLoginRequiredKugou,
      'qqmusic' => l10n.toastQqLikeSyncFailed,
      _ => l10n.toastLoginRequiredNetease,
    };
  }

  /// 行内红心切换：失败提示登录（对齐「我喜欢」页 _toggleLike 语义；
  /// 成功由 SongList 红心填充态即时反馈，不再 toast）。QQ 走本地红心
  /// （未登录也成功）；仅登录后的在线实验收藏失败才回滚并提示。
  Future<void> _toggleLike(Track track) async {
    final controller = ref.read(likeControllerProvider);
    final ok = await controller.toggle(track);
    if (!mounted) return;
    if (!ok) {
      _toast(_likeFailText(track.source));
    }
  }
}
