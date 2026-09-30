// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../services/spotlight/spotlight.dart';
import '../../stores/providers.dart';
import '../../stores/spotlight_provider.dart';
import '../common/toast.dart';
import '../list/cover_image.dart';
import '../player/s_controls.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

/// 首页「随机聚光」卡片：随机来源 + 随机起始曲 + 预览，可播放 / 换一批。
///
/// 与「固定横幅」不同：内容由 [spotlightProvider] 决定（同一逻辑日可复现，
/// 支持换一批）；无任何可用来源时回落为登录提示 / 空态。
class HomeSpotlightCard extends ConsumerStatefulWidget {
  const HomeSpotlightCard({super.key, required this.onOpenDaily});

  /// 点击「去登录 / 查看每日推荐」时的回调（登录门由调用方处理）。
  final VoidCallback onOpenDaily;

  @override
  ConsumerState<HomeSpotlightCard> createState() => _HomeSpotlightCardState();
}

class _HomeSpotlightCardState extends ConsumerState<HomeSpotlightCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(spotlightProvider.notifier).ensure();
    });
  }

  void _play(SpotlightPick pick) => _playAt(pick, pick.leadIndex);

  /// 从指定下标起播整组（预览行点击走这里）。
  void _playAt(SpotlightPick pick, int index) {
    if (pick.tracks.isEmpty) {
      toast(context.l10n.pageHomeSpotlightEmpty);
      return;
    }
    ref
        .read(playbackProvider.notifier)
        .playQueue(pick.tracks, startIndex: index);
  }

  @override
  Widget build(BuildContext context) {
    // 登录态变化 → 重新汇总来源（解锁 / 移除每日推荐）。
    ref.listen(neteaseAuthProvider, (prev, next) {
      if ((prev == null) != (next == null)) {
        ref.read(spotlightProvider.notifier).ensure();
      }
    });
    final state = ref.watch(spotlightProvider);
    final l10n = context.l10n;
    final pick = state.pick;
    if (pick == null) {
      return _SpotlightShell(
        child: _SpotlightPlaceholder(
          loading: state.loading || !state.ready,
          loggedIn: ref.watch(neteaseAuthProvider) != null,
          l10n: l10n,
          onAction: widget.onOpenDaily,
        ),
      );
    }
    final lead = pick.lead;
    return _SpotlightShell(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CoverImage(
            cover: lead?.cover,
            width: 96,
            height: 96,
            radius: 14,
            iconSize: 32,
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  l10n.pageHomeSpotlightTitle(song: lead?.title ?? ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  (lead?.artistNames.isNotEmpty ?? false)
                      ? lead!.artistNames
                      : l10n.pageHomeSpotlightSubtitle(
                          count: pick.tracks.length,
                        ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    SButton(
                      label: l10n.pageHomeDailyPlay,
                      icon: EtaIcons.play,
                      variant: SButtonVariant.primary,
                      size: SButtonSize.small,
                      onPressed: () => _play(pick),
                    ),
                    const SizedBox(width: 10),
                    SButton(
                      label: l10n.pageHomeSpotlightShuffle,
                      icon: EtaIcons.refresh,
                      variant: SButtonVariant.secondary,
                      size: SButtonSize.small,
                      onPressed: state.loading
                          ? null
                          : () => ref
                                .read(spotlightProvider.notifier)
                                .reroll(),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 28),
          // 预览队列（窄屏隐藏，避免挤压主信息）。
          if (MediaQuery.sizeOf(context).width >= 760)
            _SpotlightPreview(
              pick: pick,
              onPlayAt: (i) => _playAt(pick, i),
            ),
        ],
      ),
    );
  }
}

/// 卡片外壳：渐变 + 边框 + 内边距（与首页其它卡片一致）。
class _SpotlightShell extends StatelessWidget {
  const _SpotlightShell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 172),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withValues(alpha: 0.26),
            scheme.primaryContainer.withValues(alpha: 0.42),
            scheme.surfaceContainerHigh,
          ],
          stops: const [0, 0.55, 1],
        ),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.2)),
      ),
      // Material 透明层：让预览行的 InkWell 反馈绘制在渐变之上。
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}

/// 右侧预览：起始曲之后的最多 3 首，可点击从该曲起播。
class _SpotlightPreview extends StatelessWidget {
  const _SpotlightPreview({required this.pick, required this.onPlayAt});
  final SpotlightPick pick;
  final ValueChanged<int> onPlayAt;

  @override
  Widget build(BuildContext context) {
    final n = pick.tracks.length;
    final entries = <({Track track, int index})>[];
    for (var k = 1; k < 4 && k < n; k++) {
      final idx = (pick.leadIndex + k) % n;
      entries.add((track: pick.tracks[idx], index: idx));
    }
    if (entries.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      width: 320,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final e in entries)
            _SpotlightPreviewRow(
              track: e.track,
              ordinal: e.index + 1,
              onTap: () => onPlayAt(e.index),
            ),
        ],
      ),
    );
  }
}

/// 预览单行：序号 + 歌名 + 歌手（整行可点，带 hover 反馈）。
class _SpotlightPreviewRow extends StatelessWidget {
  const _SpotlightPreviewRow({
    required this.track,
    required this.ordinal,
    required this.onTap,
  });

  final Track track;
  final int ordinal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      mouseCursor: SystemMouseCursors.click,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: Text(
                ordinal.toString().padLeft(2, '0'),
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                track.artistNames,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 占位：加载中 / 未登录提示 / 无可用来源。
class _SpotlightPlaceholder extends StatelessWidget {
  const _SpotlightPlaceholder({
    required this.loading,
    required this.loggedIn,
    required this.l10n,
    required this.onAction,
  });

  final bool loading;
  final bool loggedIn;
  final AppLocalizations l10n;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(EtaIcons.sunOutline, size: 56, color: scheme.primary),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                l10n.pageHomeDaily,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                loggedIn
                    ? l10n.pageHomeSpotlightEmpty
                    : l10n.pageHomeDailyLoginHint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              if (!loggedIn)
                SButton(
                  label: l10n.pageHomeDailyLogin,
                  icon: EtaIcons.entrance,
                  variant: SButtonVariant.primary,
                  size: SButtonSize.small,
                  onPressed: onAction,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
