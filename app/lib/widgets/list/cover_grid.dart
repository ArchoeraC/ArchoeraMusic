import 'package:flutter/material.dart';

import '../../services/netease/netease_api.dart';
import '../../l10n/generated/app_localizations.dart';
import '../common/anim.dart';

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
    this.shrinkWrap = false,
    this.physics,
  });

  final List<CoverItem> items;
  final ValueChanged<CoverItem> onTap;

  /// 封面右下角「全部播放」按钮（点击播放整项；null 则不显示可点按钮）。
  final ValueChanged<CoverItem>? onPlay;

  /// 触底加载中（显示尾部 loading 项）。
  final bool loading;

  /// 还有下一页（保留尾部 loading 项空间）。
  final bool hasMore;
  final VoidCallback? onReachBottom;
  final double maxCrossAxisExtent;
  final double childAspectRatio;

  /// 封面圆角（设置「封面圆角」传入；默认 10）。
  final double radius;

  /// 歌手网格（圆形头像，对齐原版 CoverCard type=artist）。
  final bool artist;

  /// 内嵌滚动容器（SingleChildScrollView / ListView 等无界高度场景）时
  /// 需收缩自身高度并禁用自身滚动，交由外层滚动。
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

  /// 封面右下角「全部播放」按钮（点击播放整项；null 则不显示可点按钮）。
  final ValueChanged<CoverItem>? onPlay;
  final double cardWidth;
  final double height;
  final bool loading;

  /// 封面圆角（设置「封面圆角」传入；默认 10）。
  final double radius;

  /// 歌手走带（圆形头像）。
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
  });

  final CoverItem item;
  final VoidCallback? onTap;

  /// 封面右下角「全部播放」按钮（点击播放整项；null 则不显示可点按钮）。
  final VoidCallback? onPlay;
  final double radius;
  final String? subtitleOverride;

  /// 歌手卡片（圆形头像 + 悬浮居中用户图标 + 文本居中，对齐原版 CoverCard type=artist）。
  final bool artist;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final placeholder = Container(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
      child: Icon(
        artist ? Icons.person : Icons.music_note,
        size: 40,
        color: theme.colorScheme.primary,
      ),
    );
    final subtitle = subtitleOverride ??
        (item.subtitle.isEmpty
            ? (item.trackCount > 0 ? l10n.commonTrackCount(item.trackCount) : '')
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
            crossAxisAlignment:
                artist ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              Expanded(
                // 非歌手卡片：圆角方形封面；歌手卡片保持圆形头像（对齐原版
                // CoverList type=artist 的圆形设计）。
                child: artist
                    ? ClipOval(
                        child: _coverBody(item, placeholder, theme, onTap),
                      )
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(radius),
                        child: _coverBody(item, placeholder, theme, onTap),
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

  /// 封面本体：方形内容区 + 悬浮遮罩（由外层 Clip 决定圆角/圆形裁剪）。
  Widget _coverBody(CoverItem item, Widget placeholder, ThemeData theme,
      VoidCallback? onTap) {
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
              errorBuilder: (_, _, _) => placeholder,
              loadingBuilder: (context, child, progress) =>
                  progress == null ? child : placeholder,
            ),
          // 悬浮遮罩（对齐原版 group-hover 效果）
          if (onTap != null)
            Positioned.fill(
              child: _HoverOverlay(
                visible: artist,
                icon: artist ? Icons.person : Icons.play_arrow_rounded,
                color: theme.colorScheme.primary,
                childColor: Colors.white,
                onPlay: artist ? null : onPlay,
              ),
            ),
        ],
      ),
    );
  }
}

/// 悬浮遮罩：默认歌手居中显示用户图标；歌单右下角显示播放按钮（对齐原版 hover 动效）。
class _HoverOverlay extends StatefulWidget {
  const _HoverOverlay({
    required this.visible,
    required this.icon,
    required this.color,
    required this.childColor,
    this.onPlay,
  });

  /// artist 模式居中显示；非 artist 模式右下角。
  final bool visible;
  final IconData icon;
  final Color color;
  final Color childColor;

  /// 非 artist 模式右下角播放按钮点击（播放全部；null 则仅展示）。
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
          // 未悬停（按钮透明）时不拦截点击：点击落到卡片 InkWell
          // （进入详情）；悬停后才可点按钮触发「播放全部」。
          child: IgnorePointer(
            ignoring: !_hovered,
            child: _playButton(),
          ),
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
    // 可点击时包 GestureDetector：内层赢得手势竞技场，不会触发外层
    // 卡片 InkWell 的 onTap（进入详情），实现「播放全部」独立点击。
    final button = widget.onPlay == null
        ? circle
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPlay,
            child: circle,
          );
    return Align(
      alignment: Alignment.bottomRight,
      child: button,
    );
  }
}
