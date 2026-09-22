// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: invalid_use_of_protected_member

part of '../liked_page.dart';

extension _LikedPageView on _LikedPageState {
  Widget _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final playingId = ref.watch(playbackProvider.select((s) => s.trackId));
    final isPlaying = ref.watch(playbackProvider.select((s) => s.playing));

    // 各平台登录态变化 → 重置/重载（信号由注册表适配器提供）。
    for (final p in collectionPlatforms(ref)) {
      ref.listen(p.authSignal, (_, _) => _onAuthChanged(p.source));
    }
    // 实验性音源开关影响下拉选项（collectionPlatforms 读 enabled）：watch 触发重建。
    ref.watch(appPrefsProvider.select((p) => p.nekoEnabled));
    // 实验性音源关闭时，若当前停留在 NK 平台则退回默认。
    ref.listen(appPrefsProvider.select((p) => p.nekoEnabled), (prev, next) {
      if (next == false && _platform == 'neko') {
        _switchPlatform(defaultLikedPlatform(ref));
      }
    });

    // 两个可能的「我喜欢」后端（服务端 store / QQ 本机库）变化都会触发重建。
    ref.watch(likedStoreProvider);
    ref.watch(qqLikedStoreProvider);

    final adapter = collectionPlatform(_platform);
    final view = adapter.likedView(ref);
    final available = adapter.likedAvailable(ref);

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _LikedHeader(
            subtitle: adapter.likedSubtitle(ref, l10n, view),
            platform: _platform,
            platforms: collectionPlatforms(ref),
            loggedIn: available,
            showPlayAll: available && view.loaded && view.tracks.isNotEmpty,
            showRefresh: available && adapter.likedShowRefresh(ref, view),
            refreshLabel: adapter.likedRefreshLabel(l10n),
            resolving: _resolving,
            onPlayAll: _playAll,
            onSwitchPlatform: _switchPlatform,
            onRefresh: () => adapter.likedRefresh(context, ref),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          Expanded(
            child: _buildContent(
              theme: theme,
              scheme: scheme,
              l10n: l10n,
              adapter: adapter,
              view: view,
              playingId: playingId,
              isPlaying: isPlaying,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent({
    required ThemeData theme,
    required ColorScheme scheme,
    required AppLocalizations l10n,
    required CollectionPlatform adapter,
    required LikedView view,
    required String? playingId,
    required bool isPlaying,
  }) {
    if (!adapter.likedAvailable(ref)) {
      return StreamingEmptyState(
        icon: EtaIcons.heartOutline,
        title: l10n.pageLikedLoginTitle,
        subtitle: adapter.likedLoginDesc(l10n),
        buttonLabel: l10n.navHeaderQrLogin,
        buttonIcon: EtaIcons.qrcode,
        onButton: () => adapter.login(context),
      );
    }
    if (view.loading && !view.loaded) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (view.error.isNotEmpty && !view.loaded) {
      return _LikedErrorCard(
        theme: theme,
        scheme: scheme,
        title: l10n.pageLikedLoadFailed,
        message: view.error,
        onRetry: () => adapter.likedRefresh(context, ref),
      );
    }
    if (view.tracks.isEmpty) {
      final action = adapter.likedEmptyAction(l10n, ref);
      return _LikedEmptyState(
        theme: theme,
        scheme: scheme,
        title: adapter.likedEmptyTitle(l10n),
        message: adapter.likedEmptyHint(l10n),
        actionLabel: action?.label,
        onAction: action == null ? null : () => action.run(context, ref),
      );
    }
    return SongList(
      key: const PageStorageKey('page.liked'),
      items: view.tracks,
      playingId: playingId,
      isPlaying: isPlaying,
      onPlay: _playTrack,
      onContextMenu: _onTrackMenu,
      likedIds: view.likeIds,
      onToggleLike: _toggleLike,
    );
  }
}

class _LikedHeader extends StatelessWidget {
  const _LikedHeader({
    required this.subtitle,
    required this.platform,
    required this.platforms,
    required this.loggedIn,
    required this.showPlayAll,
    required this.showRefresh,
    required this.refreshLabel,
    required this.resolving,
    required this.onPlayAll,
    required this.onSwitchPlatform,
    required this.onRefresh,
  });

  final String subtitle;
  final String platform;
  final List<CollectionPlatform> platforms;
  final bool loggedIn;
  final bool showPlayAll;
  final bool showRefresh;
  final String refreshLabel;
  final bool resolving;
  final Future<void> Function() onPlayAll;
  final ValueChanged<String> onSwitchPlatform;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return Padding(
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
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (showPlayAll) ...[
            SButton(
              label: l10n.commonPlayAll,
              icon: EtaIcons.play,
              variant: SButtonVariant.primary,
              loading: resolving,
              onPressed: onPlayAll,
            ),
            const SizedBox(width: 12),
          ],
          SDropdown<String>(
            options: [
              for (final p in platforms)
                SDropdownOption(p.source, p.label(l10n)),
            ],
            selected: platform,
            onChanged: onSwitchPlatform,
          ),
          const SizedBox(width: 12),
          if (showRefresh)
            SButton(
              label: refreshLabel,
              icon: EtaIcons.refresh,
              variant: SButtonVariant.secondary,
              onPressed: onRefresh,
            ),
        ],
      ),
    );
  }
}

class _LikedErrorCard extends StatelessWidget {
  const _LikedErrorCard({
    required this.theme,
    required this.scheme,
    required this.title,
    required this.message,
    required this.onRetry,
  });

  final ThemeData theme;
  final ColorScheme scheme;
  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(EtaIcons.alertOutline, size: 48, color: scheme.error),
          const SizedBox(height: 10),
          Text(title, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          SButton(
            label: context.l10n.commonRetry,
            icon: EtaIcons.refresh,
            variant: SButtonVariant.secondary,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

class _LikedEmptyState extends StatelessWidget {
  const _LikedEmptyState({
    required this.theme,
    required this.scheme,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final ThemeData theme;
  final ColorScheme scheme;
  final String title;
  final String message;

  /// 可选的空态动作（QQ 平台：登录 / 同步在线收藏）。
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final label = actionLabel;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            EtaIcons.heartOutline,
            size: 48,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 10),
          Text(title, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (label != null && onAction != null) ...[
            const SizedBox(height: 16),
            SButton(
              label: label,
              icon: EtaIcons.refresh,
              variant: SButtonVariant.secondary,
              onPressed: onAction,
            ),
          ],
        ],
      ),
    );
  }
}
