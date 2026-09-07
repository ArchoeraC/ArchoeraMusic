// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../streaming_page.dart';

extension _StreamingPageView on _StreamingPageState {
  Widget _buildStreamingPage(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(streamingProvider);

    // 连接成功 → 自动拉取当前 Tab 数据
    ref.listen(streamingProvider.select((s) => s.connected), (_, connected) {
      if (connected) _fetchCurrent();
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 顶栏 ─────────────────────────────────────────────
        // 对齐其他页面顶栏（24 左侧 / 20 顶部），避免标题相对偏上偏左
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 10),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text(
                      l10n.sidebarStreaming,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (state.activeServer != null) ...[
                      const SizedBox(width: 12),
                      StreamingCountLabel(
                        index: _tab.index,
                        state: state,
                        l10n: l10n,
                      ),
                    ],
                  ],
                ),
              ),
              if (state.activeServer != null) ...[
                StreamingStatusDot(state: state, scheme: scheme),
                const SizedBox(width: 10),
                StreamingServerDropdown(state: state),
                const SizedBox(width: 8),
                SButton(
                  label: '',
                  icon: EtaIcons.refresh,
                  variant: SButtonVariant.secondary,
                  size: SButtonSize.medium,
                  circle: true,
                  loading: state.loading,
                  onPressed: (state.connected && !state.loading)
                      ? _refreshCurrent
                      : null,
                ),
                const SizedBox(width: 8),
                SButton(
                  label: '',
                  icon: EtaIcons.settingsOutline,
                  variant: SButtonVariant.secondary,
                  size: SButtonSize.medium,
                  circle: true,
                  onPressed: _openStreamingSettings,
                ),
              ],
            ],
          ),
        ),
        // ── Tab ──────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: TabBar(
            controller: _tab,
            // TabAlignment.start 仅对可滚动 TabBar 有效：必须 isScrollable，
            // 否则指示条偏移与标签不一致（对「歌单」高亮定位错误）。
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: l10n.streamingTabsSongs),
              Tab(text: l10n.streamingTabsAlbums),
              Tab(text: l10n.streamingTabsArtists),
              Tab(text: l10n.streamingTabsPlaylists),
            ],
          ),
        ),
        const Divider(height: 1),
        // ── 内容状态机 ────────────────────────────────────────
        Expanded(child: _buildStreamingContent(state, l10n, scheme)),
      ],
    );
  }

  Widget _buildStreamingContent(
    StreamingState state,
    AppLocalizations l10n,
    ColorScheme scheme,
  ) {
    // 未配置任何服务器
    if (state.servers.isEmpty) {
      return StreamingEmptyState(
        icon: EtaIcons.serverOutline,
        title: l10n.streamingEmptyNoServer,
        subtitle: l10n.streamingEmptyAddHint,
        buttonLabel: l10n.streamingEmptyGoToSettings,
        onButton: _openStreamingSettings,
      );
    }
    // 已配置但未连接
    if (!state.connected) {
      return StreamingEmptyState(
        icon: EtaIcons.unlink,
        title: l10n.streamingEmptyNotConnected,
        subtitle:
            state.connectionError ??
            state.activeServer?.name ??
            l10n.streamingServerDisconnected,
        subtitleError: state.connectionError != null,
        buttonLabel: l10n.streamingServerConnect,
        buttonLoading: state.connecting,
        onButton: _connectStreaming,
      );
    }
    // 已连接：四个 Tab 内容（IndexedStack 保留滚动位置）
    return IndexedStack(
      index: _tab.index,
      children: const [
        StreamingSongsTab(),
        StreamingAlbumsTab(),
        StreamingArtistsTab(),
        StreamingPlaylistsTab(),
      ],
    );
  }
}
