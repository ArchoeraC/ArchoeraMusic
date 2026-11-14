// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_dialog.dart';

extension _SettingsDialogView on _SettingsDialogState {
  Widget _buildSettingsDialog(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final window = MediaQuery.sizeOf(context);
    final navStyle = sidebarNavStyleFor(
      ref.watch(appPrefsProvider).sidebarNavStyle,
    );
    final indicator = navStyle.slidingIndicator && _catIndicatorReady
        ? navStyle.buildContainerIndicator(
            context: context,
            color: scheme.primary,
            left: _catIndicatorLeft,
            top: _catIndicatorTop,
            height: _catIndicatorHeight,
          )
        : null;
    final devMode = ref.watch(appPrefsProvider).developerMode;
    final downloadModule = ref.watch(appPrefsProvider).downloadModuleEnabled;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _updateCategoryIndicator(),
    );
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.dialog),
        side: BorderSide(color: scheme.outline.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: GlassDialogSurface(
        radius: BorderRadius.circular(AppRadius.dialog),
        color: scheme.surfaceContainerHighest,
        child: SizedBox(
          width: (window.width * 0.8).clamp(640.0, 960.0),
          height: (window.height * 0.84).clamp(480.0, 660.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 210,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.settingsTitle,
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: l10n.commonClose,
                            iconSize: 18,
                            visualDensity: VisualDensity.compact,
                            onPressed: () => Navigator.of(context).pop(),
                            icon: Icon(
                              EtaIcons.close,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.appName,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Expanded(
                        child: Stack(
                          key: _catHostKey,
                          children: [
                            // 隐藏侧栏滚动条（保留滚轮 / 拖拽滚动）。
                            ScrollConfiguration(
                              behavior: const _NoScrollbarBehavior(),
                              child: InkClip(
                                child: ListView(
                                  controller: _catScrollCtrl,
                                  padding: EdgeInsets.zero,
                                  // 每项恒为 40 高 + 上下各 1.5 的 padding。
                                  itemExtent: 43,
                                  children: [
                                    for (final cat in SettingsCategory.values)
                                      if (cat.visible(devMode, downloadModule))
                                        _buildCategoryItem(
                                          scheme,
                                          cat,
                                          l10n,
                                          navStyle,
                                        ),
                                  ],
                                ),
                              ),
                            ),
                            ?indicator,
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                  // Stack 作为搜索跳转高亮的坐标参照系（_contentHostKey）。
                  child: Stack(
                    key: _contentHostKey,
                    fit: StackFit.expand,
                    children: [
                      _buildContent(scheme, l10n),
                      if (_flashRect != null)
                        Positioned.fromRect(
                          rect: _flashRect!,
                          child: IgnorePointer(
                            child: SettingsRowFlash(
                              animation: _flashCtrl,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 搜索索引 = 源码生成的设置项标题（`settings_search_index.g.dart`）
  /// + 快捷键动作（标题由 [ShortcutAction] 动态生成，无法静态扫描）。
  ///
  /// 索引完全由设置源码派生：新增/改名设置项只要跑一次
  /// `dart run tool/gen_settings_search_index.dart`（各平台构建脚本会自动跑），
  /// 无需手工登记。可见性（开发者模式、下载模块）仍由
  /// [SettingsCategory.visible] 在展示时过滤，不影响关于页长按等彩蛋逻辑。
  List<_SearchEntry> _buildSearchIndex(AppLocalizations l10n) {
    final all = <_SearchEntry>[
      ..._generatedSettingsSearchIndex(l10n),
      for (final a in ShortcutAction.values)
        _SearchEntry(
          SettingsCategory.shortcuts,
          shortcutActionLabel(l10n, a),
          l10n.shortcutHintEdit,
          SettingsCategory.shortcuts.icon,
        ),
    ];
    // 同一分类内按标题去重：小节标题与设置行可能同名（如「界面语言」既是
    // 小节名也是设置项名），重复条目会让结果列表出现两条一模一样的文字。
    // 保留后出现的（设置行在后，副标题更有信息量；锚点也指向它）。
    final byTitle = <String, _SearchEntry>{};
    for (final e in all) {
      byTitle['${e.category.name}\u0000${e.title}'] = e;
    }
    return byTitle.values.toList(growable: false);
  }

  Widget _buildCategoryItem(
    ColorScheme scheme,
    SettingsCategory cat,
    AppLocalizations l10n,
    SidebarNavStyle navStyle,
  ) {
    final selected = _category == cat;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: AnimatedContainer(
        key: _catKeys[cat] ??= GlobalKey(),
        duration: animDuration(context, const Duration(milliseconds: 150)),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            hoverColor: selected
                ? Colors.transparent
                : scheme.onSurface.withValues(alpha: 0.05),
            onTap: () => _setCategory(cat),
            child: SizedBox(
              height: 40,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned(
                    left: 0,
                    top: 10,
                    bottom: 10,
                    child: AnimatedContainer(
                      duration: animDuration(
                        context,
                        const Duration(milliseconds: 150),
                      ),
                      width: 3,
                      decoration: BoxDecoration(
                        color: !navStyle.slidingIndicator && selected
                            ? scheme.primary
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Row(
                      children: [
                        Icon(
                          cat.icon,
                          size: 18,
                          color: selected ? scheme.primary : scheme.onSurface,
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            cat.label(l10n),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: selected
                                  ? scheme.primary
                                  : scheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(ColorScheme scheme, AppLocalizations l10n) {
    final searching = _query.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSearchField(scheme, l10n),
        const SizedBox(height: 14),
        if (searching)
          Expanded(child: _buildSearchResults(scheme, l10n))
        else ...[
          Text(
            _category.label(l10n),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _category.subtitle(l10n),
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: InkClip(
              child: SingleChildScrollView(
                controller: _contentScrollCtrl,
                child: switch (_category) {
                  SettingsCategory.appearance => const AppearanceSection(),
                  SettingsCategory.playback => const PlaybackSection(),
                  SettingsCategory.audioEffects => const AudioEffectsSection(),
                  SettingsCategory.shortcuts => const ShortcutsSection(),
                  SettingsCategory.lyrics => const LyricsSection(),
                  SettingsCategory.preset => const PresetSection(),
                  SettingsCategory.render => const RenderSection(),
                  SettingsCategory.download => const DownloadSection(),
                  SettingsCategory.storage => const Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      CacheSection(),
                      HistorySection(),
                      StorageSection(),
                      SecuritySection(),
                    ],
                  ),
                  SettingsCategory.scrape => const ScrapeSection(),
                  SettingsCategory.scanner => const ScansSection(),
                  SettingsCategory.searchIndex => const SearchSection(),
                  SettingsCategory.mediaSource => StreamingServerList(),
                  SettingsCategory.experimentalSource =>
                    const ExperimentalSourceSection(),
                  SettingsCategory.mcp => const McpSection(),
                  SettingsCategory.about => AboutSection(
                    version: _version,
                    devHolding: _devHolding,
                    devHoldProgress: _devHoldProgress,
                    eggUnlocked: _eggUnlocked,
                    onDevHoldStart: _startDevHold,
                    onDevHoldCancel: _cancelDevHold,
                  ),
                  SettingsCategory.developer => DeveloperSection(
                    onDeveloperDisabled: () {
                      if (mounted) _setCategory(SettingsCategory.about);
                    },
                  ),
                },
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSearchField(ColorScheme scheme, AppLocalizations l10n) {
    return TextField(
      controller: _searchCtrl,
      onChanged: _setQuery,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        hintText: l10n.settingsSearchHint,
        prefixIcon: const Icon(EtaIcons.search2, size: 18),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                tooltip: l10n.commonClear,
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: const Icon(EtaIcons.close),
                onPressed: _clearQuery,
              ),
        isDense: true,
      ),
    );
  }

  Widget _buildSearchResults(ColorScheme scheme, AppLocalizations l10n) {
    final q = _query.trim().toLowerCase();
    final devMode = ref.watch(appPrefsProvider).developerMode;
    final downloadModule = ref.watch(appPrefsProvider).downloadModuleEnabled;
    final index = _buildSearchIndex(l10n)
        .where((e) => e.category.visible(devMode, downloadModule))
        .toList();
    final matches = index.where((e) => _searchMatch(e, q, l10n)).toList();
    // 暗号精确命中时才浮现彩蛋入口；不附带任何说明文字。
    final unlock = q == kEasterEggUnlockQuery;
    if (matches.isEmpty && !unlock) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              EtaIcons.search2None,
              size: 36,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.settingsSearchNoResult(query: _query),
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }
    return InkClip(
      child: SingleChildScrollView(
        controller: _searchScrollCtrl,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (unlock) ...[
              _buildEasterEggResultTile(scheme, l10n),
              if (matches.isNotEmpty) const SizedBox(height: 10),
            ],
            if (matches.isNotEmpty) ...[
              Text(
                l10n.settingsSearchMatchCount(count: matches.length),
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 8),
            ],
            for (final cat in SettingsCategory.values)
              if (cat.visible(devMode, downloadModule) &&
                  matches.any((e) => e.category == cat)) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Icon(cat.icon, size: 13, color: scheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        cat.label(l10n),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: scheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                for (final e in matches.where((e) => e.category == cat))
                  _buildSearchResultTile(scheme, e, q),
              ],
          ],
        ),
      ),
    );
  }

  /// 暗号命中的彩蛋入口：外观与普通搜索结果一致，但不附任何说明文字。
  Widget _buildEasterEggResultTile(ColorScheme scheme, AppLocalizations l10n) {
    return Material(
      color: scheme.error.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        hoverColor: scheme.onSurface.withValues(alpha: 0.05),
        onTap: () => showEasterEggGate(context, ref: ref),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(EtaIcons.alert, size: 17, color: scheme.error),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l10n.settingsNeverTap,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              Icon(
                EtaIcons.rightSmall,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _searchMatch(_SearchEntry e, String q, AppLocalizations l10n) =>
      e.title.toLowerCase().contains(q) ||
      e.subtitle.toLowerCase().contains(q) ||
      e.category.label(l10n).toLowerCase().contains(q);

  Widget _buildSearchResultTile(ColorScheme scheme, _SearchEntry e, String q) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: scheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          hoverColor: scheme.onSurface.withValues(alpha: 0.05),
          onTap: () => _jumpToSearchEntry(e),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(e.icon, size: 17, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: _highlight(e.title, q, scheme),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: scheme.onSurface,
                          ),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (e.subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          e.subtitle,
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant.withValues(
                              alpha: 0.7,
                            ),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  EtaIcons.rightSmall,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<InlineSpan> _highlight(String text, String q, ColorScheme scheme) {
    final lower = text.toLowerCase();
    final spans = <InlineSpan>[];
    var start = 0;
    while (true) {
      final idx = lower.indexOf(q, start);
      if (idx < 0) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
      spans.add(
        TextSpan(
          text: text.substring(idx, idx + q.length),
          style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700),
        ),
      );
      start = idx + q.length;
    }
    return spans;
  }
}

/// 搜索命中的设置行高亮：在目标位置脉冲 [SettingsDialog] 设置的高亮框。
///
/// 只画描边 + 淡填充、不拦截指针事件；3 次脉冲后由外层清掉 [Rect] 移除。
class SettingsRowFlash extends StatelessWidget {
  const SettingsRowFlash({
    super.key,
    required this.animation,
    required this.color,
  });

  final Animation<double> animation;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value.clamp(0.0, 1.0);
        // 每个周期 0 → 1 → 0；t=1 时相位归零，强度自然回到 0。
        final phase = (t * _SettingsDialogState._flashPulses) % 1.0;
        final intensity = math.sin(phase * math.pi).abs() * (1 - t * 0.2);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10 * intensity),
            border: Border.all(
              color: color.withValues(alpha: 0.9 * intensity),
              width: 1.6,
            ),
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
        );
      },
    );
  }
}

/// 不构建滚动条（隐藏滚动条的列表仍可滚轮 / 拖拽滚动）。
class _NoScrollbarBehavior extends ScrollBehavior {
  const _NoScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}
