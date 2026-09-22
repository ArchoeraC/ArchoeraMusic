// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../favorites_page.dart';

extension _FavoritesPageView on _FavoritesPageState {
  Widget _buildFavoritesPage(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;

    // 各平台登录态变化 → 清缓存并按需刷新（信号由注册表提供）。
    for (final p in collectionPlatforms(ref)) {
      ref.listen(p.authSignal, (_, _) => _onAuthChanged());
    }
    // 实验性音源开关影响下拉选项（collectionPlatforms 读 enabled）：watch 触发重建。
    ref.watch(appPrefsProvider.select((p) => p.nekoEnabled));
    // 实验性音源关闭时，若当前停留在 NK 平台则退回 NT。
    ref.listen(appPrefsProvider.select((p) => p.nekoEnabled), (prev, next) {
      if (next == false && _platform == 'neko') _switchPlatform('netease');
    });

    final adapter = _adapter;
    final tabs = adapter.tabs(l10n);
    final selectedTab = tabs.firstWhere(
      (t) => t.id == _tab,
      orElse: () => tabs.first,
    );
    final items = _cache[_cacheKey] ?? const <CoverItem>[];
    final loading = _loading.contains(_cacheKey);
    final error = _error[_cacheKey] ?? '';
    final count = items.length;
    final loggedIn = _loggedIn;
    final subtitle = adapter.favTabSubtitle(l10n, _tab, count, loggedIn);

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 标题 + 平台切换 ────────────────────────────────────
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
                        l10n.sidebarFavorites,
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
                SDropdown<String>(
                  options: [
                    for (final p in collectionPlatforms(ref))
                      SDropdownOption(p.source, p.label(l10n)),
                  ],
                  selected: _platform,
                  onChanged: _switchPlatform,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // ── 分类 tab ────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SSegmented<String>(
                options: [
                  for (final t in tabs)
                    SSegmentedOption(t.id, t.label(l10n)),
                ],
                selected: _tab,
                onChanged: _switchTab,
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          // ── 内容区状态机 ─────────────────────────────────────
          Expanded(
            child: !loggedIn
                ? StreamingEmptyState(
                    icon: EtaIcons.starOutline,
                    title: l10n.pageFavLoginTitle,
                    subtitle: adapter.favLoginDesc(l10n),
                    buttonLabel: l10n.navHeaderQrLogin,
                    buttonIcon: EtaIcons.qrcode,
                    onButton: _login,
                  )
                : loading && !_loaded.contains(_cacheKey)
                ? const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  )
                : error.isNotEmpty && !_loaded.contains(_cacheKey)
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          EtaIcons.alertOutline,
                          size: 48,
                          color: scheme.error,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          l10n.pageFavLoadFailed,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          error,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 14),
                        SButton(
                          label: l10n.commonRetry,
                          icon: EtaIcons.refresh,
                          variant: SButtonVariant.secondary,
                          onPressed: _fetch,
                        ),
                      ],
                    ),
                  )
                : items.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          selectedTab.icon,
                          size: 48,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          l10n.pageFavEmpty,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          adapter.favEmptyHint(l10n),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                : CoverGrid(
                    key: const PageStorageKey('page.favorites'),
                    items: items,
                    onTap: _onCoverTap,
                    maxCrossAxisExtent: selectedTab.extent,
                  ),
          ),
        ],
      ),
    );
  }
}
