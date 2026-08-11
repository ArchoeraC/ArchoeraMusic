/// 流媒体主页（对齐 SPlayer-Next Streaming/Index.vue）。
///
/// 顶栏：标题 + 数量统计；右侧状态点 / 服务器下拉 / 刷新 / 设置。
/// Tab：歌曲 / 专辑 / 歌手 / 歌单（懒加载缓存，切换 Tab 拉取）。
/// 状态机：无服务器 → 空态引导去设置；已配置未连接 → 错误 + 重连；
/// 已连接 → 四个 Tab 内容（歌曲列表 / 封面网格）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../settings/settings_dialog.dart';
import '../../widgets/player/s_controls.dart';
import '../../widgets/streaming/albums_tab.dart';
import '../../widgets/streaming/artists_tab.dart';
import '../../widgets/streaming/count_label.dart';
import '../../widgets/streaming/empty_state.dart';
import '../../widgets/streaming/playlists_tab.dart';
import '../../widgets/streaming/server_dropdown.dart';
import '../../widgets/streaming/songs_tab.dart';
import '../../widgets/streaming/status_dot.dart';
import '../../services/streaming/streaming_provider.dart';

/// 流媒体主页（壳内分支 /streaming）。
class StreamingPage extends ConsumerStatefulWidget {
  const StreamingPage({super.key});

  @override
  ConsumerState<StreamingPage> createState() => _StreamingPageState();
}

class _StreamingPageState extends ConsumerState<StreamingPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
    _tab.addListener(_onTabChanged);
    // 启动时自动连接已有激活服务器（不阻塞首帧）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(streamingProvider.notifier).init();
    });
  }

  @override
  void dispose() {
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tab.indexIsChanging) return;
    _fetchCurrent();
  }

  void _fetchCurrent() {
    final n = ref.read(streamingProvider.notifier);
    switch (_tab.index) {
      case 0:
        n.fetchSongs();
      case 1:
        n.fetchAlbums();
      case 2:
        n.fetchArtists();
      default:
        n.fetchPlaylists();
    }
  }

  void _refreshCurrent() {
    final n = ref.read(streamingProvider.notifier);
    switch (_tab.index) {
      case 0:
        n.refresh(tab: 'songs');
      case 1:
        n.refresh(tab: 'albums');
      case 2:
        n.refresh(tab: 'artists');
      default:
        n.refresh(tab: 'playlists');
    }
  }

  @override
  Widget build(BuildContext context) {
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
                  icon: Icons.refresh,
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
                  icon: Icons.settings_outlined,
                  variant: SButtonVariant.secondary,
                  size: SButtonSize.medium,
                  circle: true,
                  onPressed: () => showSettingsDialog(
                    context,
                    category: SettingsCategory.mediaSource,
                  ),
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
        Expanded(child: _buildContent(state, l10n, scheme)),
      ],
    );
  }

  Widget _buildContent(
    StreamingState state,
    AppLocalizations l10n,
    ColorScheme scheme,
  ) {
    // 未配置任何服务器
    if (state.servers.isEmpty) {
      return StreamingEmptyState(
        icon: Icons.dns_outlined,
        title: l10n.streamingEmptyNoServer,
        subtitle: l10n.streamingEmptyAddHint,
        buttonLabel: l10n.streamingEmptyGoToSettings,
        onButton: () => showSettingsDialog(
          context,
          category: SettingsCategory.mediaSource,
        ),
      );
    }
    // 已配置但未连接
    if (!state.connected) {
      return StreamingEmptyState(
        icon: Icons.link_off,
        title: l10n.streamingEmptyNotConnected,
        subtitle: state.connectionError ??
            state.activeServer?.name ??
            l10n.streamingServerDisconnected,
        subtitleError: state.connectionError != null,
        buttonLabel: l10n.streamingServerConnect,
        buttonLoading: state.connecting,
        onButton: () => ref.read(streamingProvider.notifier).connect(),
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
