/// 流媒体详情页共享骨架（专辑 / 歌手 / 歌单三页复用）。
///
/// 结构：返回栏 + [DetailHeader]（封面/标题/副标题/播放全部）+ 分割线 +
/// [DetailBody]（加载 / 错误重试 / 子内容）。相似布局统一入口，避免三页
/// 各自重复实现。
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../widgets/list/cover_image.dart';
import '../../widgets/player/s_controls.dart';

/// 详情页骨架：返回栏 + 头部 + 内容。
class DetailScaffold extends StatelessWidget {
  const DetailScaffold({super.key, required this.header, required this.body});

  final Widget header;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 返回栏
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: IconButton(
              tooltip: context.l10n.commonBack,
              iconSize: 20,
              visualDensity: VisualDensity.compact,
              onPressed: () => context.pop(),
              icon: Icon(Icons.arrow_back, color: scheme.onSurface),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: header,
        ),
        const Divider(height: 1),
        Expanded(child: body),
      ],
    );
  }
}

/// 详情头部：封面 + 标题 + 副标题 + 播放全部。
class DetailHeader extends StatelessWidget {
  const DetailHeader({
    super.key,
    required this.title,
    this.cover,
    this.circle = false,
    this.subtitle = '',
    this.onPlayAll,
  });

  final String? cover;
  final bool circle;
  final String title;
  final String subtitle;
  final VoidCallback? onPlayAll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (circle)
          ClipOval(
            child: CoverImage(cover: cover, width: 108, height: 108, radius: 54),
          )
        else
          CoverImage(cover: cover, width: 108, height: 108, radius: 12),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title.isEmpty ? l10n.commonUnknownAlbum : title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                  height: 1.3,
                ),
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    height: 1.4,
                  ),
                ),
              ],
              if (onPlayAll != null) ...[
                const SizedBox(height: 12),
                SButton(
                  label: l10n.commonPlayAll,
                  icon: Icons.play_arrow,
                  variant: SButtonVariant.primary,
                  size: SButtonSize.small,
                  onPressed: onPlayAll,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 详情内容状态：加载 / 错误 / 子内容。
class DetailBody extends StatelessWidget {
  const DetailBody({
    super.key,
    required this.loading,
    required this.error,
    required this.l10n,
    required this.scheme,
    required this.onRetry,
    required this.child,
  });

  final bool loading;
  final String? error;
  final AppLocalizations l10n;
  final ColorScheme scheme;
  final VoidCallback onRetry;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 36,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 10),
            Text(
              error == 'no-server' ? l10n.streamingEmptyNotConnected : '$error',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 12),
            SButton(
              label: l10n.commonRetry,
              icon: Icons.refresh,
              variant: SButtonVariant.secondary,
              size: SButtonSize.small,
              onPressed: onRetry,
            ),
          ],
        ),
      );
    }
    return child;
  }
}

/// 区块标题（歌手页：专辑 / 歌曲）。
class DetailSectionTitle extends StatelessWidget {
  const DetailSectionTitle({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
    );
  }
}
