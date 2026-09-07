// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../cover_grid.dart';

/// 封面网格（专辑 / 歌手 / 歌单共用，对齐原项目 CoverList）。
///
/// 供搜索页、主页、歌单详情等复用：[CoverCard] 可单独用于横向列表。
class CoverGrid extends StatelessWidget {
  const CoverGrid({
    super.key,
    required this.items,
    required this.onTap,
    this.onPlay,
    this.loading = false,
    this.hasMore = false,
    this.onReachBottom,
    this.maxCrossAxisExtent = 180,
    this.childAspectRatio = 0.78,
    this.radius = 10,
    this.artist = false,
    this.showSource = false,
    this.shrinkWrap = false,
    this.physics,
  });

  final List<CoverItem> items;
  final ValueChanged<CoverItem> onTap;
  final ValueChanged<CoverItem>? onPlay;
  final bool loading;
  final bool hasMore;
  final VoidCallback? onReachBottom;
  final double maxCrossAxisExtent;
  final double childAspectRatio;
  final double radius;
  final bool artist;
  final bool showSource;
  final bool shrinkWrap;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty && !loading) {
      return const SizedBox.shrink();
    }
    final grid = GridView.builder(
      shrinkWrap: shrinkWrap,
      physics: physics,
      padding: const EdgeInsets.all(20),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxCrossAxisExtent,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: childAspectRatio,
      ),
      itemCount: items.length + (loading || hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == items.length) {
          return const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final item = items[index];
        return CoverCard(
          item: item,
          radius: radius,
          artist: artist,
          showSource: showSource,
          onTap: () => onTap(item),
          onPlay: onPlay == null ? null : () => onPlay!(item),
        );
      },
    );
    if (onReachBottom == null) return grid;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 400) onReachBottom!();
        return false;
      },
      child: grid,
    );
  }
}

/// 横向封面走带（主页区段：推荐歌单 / 新碟 / 热门歌手）。
class CoverRail extends StatelessWidget {
  const CoverRail({
    super.key,
    required this.items,
    required this.onTap,
    this.onPlay,
    this.cardWidth = 140,
    this.height = 178,
    this.loading = false,
    this.radius = 10,
    this.artist = false,
  });

  final List<CoverItem> items;
  final ValueChanged<CoverItem> onTap;
  final ValueChanged<CoverItem>? onPlay;
  final double cardWidth;
  final double height;
  final bool loading;
  final double radius;
  final bool artist;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty && !loading) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: items.length + (loading ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (context, index) {
          if (index == items.length) {
            return const SizedBox(
              width: 40,
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final item = items[index];
          return SizedBox(
            width: cardWidth,
            child: CoverCard(
              item: item,
              radius: radius,
              artist: artist,
              onTap: () => onTap(item),
              onPlay: onPlay == null ? null : () => onPlay!(item),
            ),
          );
        },
      ),
    );
  }
}

/// 封面卡片（对齐原项目 CoverList item）。
class CoverCard extends StatelessWidget {
  const CoverCard({
    super.key,
    required this.item,
    this.onTap,
    this.onPlay,
    this.radius = 10,
    this.subtitleOverride,
    this.artist = false,
    this.showSource = false,
  });

  final CoverItem item;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;
  final double radius;
  final String? subtitleOverride;
  final bool artist;
  final bool showSource;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final placeholder = Container(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
      child: Icon(
        artist ? EtaIcons.user : EtaIcons.music,
        size: 40,
        color: theme.colorScheme.primary,
      ),
    );
    final subtitle =
        subtitleOverride ??
        (item.subtitle.isEmpty
            ? (item.trackCount > 0
                  ? l10n.commonTrackCount(item.trackCount)
                  : '')
            : item.subtitle);
    return MouseRegion(
      cursor: onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          hoverColor: theme.colorScheme.onSurface.withValues(alpha: 0.04),
          onTap: onTap,
          child: Column(
            crossAxisAlignment: artist
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              Expanded(
                child: artist
                    ? ClipOval(
                        child: _coverBody(
                          item,
                          placeholder,
                          theme,
                          onTap,
                          showSource: showSource,
                        ),
                      )
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(radius),
                        child: _coverBody(
                          item,
                          placeholder,
                          theme,
                          onTap,
                          showSource: showSource,
                        ),
                      ),
              ),
              const SizedBox(height: 8),
              Text(
                item.title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
                textAlign: artist ? TextAlign.center : null,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: artist ? TextAlign.center : null,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _coverBody(
    CoverItem item,
    Widget placeholder,
    ThemeData theme,
    VoidCallback? onTap, {
    bool showSource = false,
  }) {
    return AspectRatio(
      aspectRatio: 1,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (item.cover == null || item.cover!.isEmpty)
            placeholder
          else
            Image.network(
              item.cover!,
              fit: BoxFit.cover,
              cacheWidth: 320,
              cacheHeight: 320,
              errorBuilder: (_, _, _) => placeholder,
              loadingBuilder: (context, child, progress) =>
                  progress == null ? child : placeholder,
            ),
          if (onTap != null)
            Positioned.fill(
              child: _HoverOverlay(
                visible: artist,
                icon: artist ? EtaIcons.user : EtaIcons.play,
                color: theme.colorScheme.primary,
                childColor: Colors.white,
                onPlay: artist ? null : onPlay,
              ),
            ),
          if (showSource)
            Positioned(
              left: 6,
              top: 6,
              child: _CoverSourceTag(source: item.source),
            ),
        ],
      ),
    );
  }
}

class _CoverSourceTag extends StatelessWidget {
  const _CoverSourceTag({required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (source) {
      'netease' => ('云', const Color(0xFFC20C0C)),
      'kugou' => ('酷', const Color(0xFF00A7E0)),
      'qqmusic' => ('Q', const Color(0xFF31C27C)),
      _ => ('', Colors.transparent),
    };
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 9,
          height: 1,
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _HoverOverlay extends StatefulWidget {
  const _HoverOverlay({
    required this.visible,
    required this.icon,
    required this.color,
    required this.childColor,
    this.onPlay,
  });

  final bool visible;
  final IconData icon;
  final Color color;
  final Color childColor;
  final VoidCallback? onPlay;

  @override
  State<_HoverOverlay> createState() => _HoverOverlayState();
}

class _HoverOverlayState extends State<_HoverOverlay> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) {
      return MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedOpacity(
          opacity: _hovered ? 1 : 0,
          duration: animDuration(context, const Duration(milliseconds: 200)),
          child: IgnorePointer(ignoring: !_hovered, child: _playButton()),
        ),
      );
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedOpacity(
        opacity: _hovered ? 1 : 0,
        duration: animDuration(context, const Duration(milliseconds: 200)),
        child: Container(
          color: Colors.black.withValues(alpha: _hovered ? 0.35 : 0),
          alignment: Alignment.center,
          child: Icon(widget.icon, size: 40, color: Colors.white),
        ),
      ),
    );
  }

  Widget _playButton() {
    final circle = Container(
      width: 34,
      height: 34,
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: widget.color.withValues(alpha: 0.85),
        shape: BoxShape.circle,
      ),
      child: Icon(widget.icon, size: 20, color: widget.childColor),
    );
    final button = widget.onPlay == null
        ? circle
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPlay,
            child: circle,
          );
    return Align(alignment: Alignment.bottomRight, child: button);
  }
}
