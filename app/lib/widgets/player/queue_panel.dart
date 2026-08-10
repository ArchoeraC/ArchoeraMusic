import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../l10n/l10n.dart';
import '../../utils/format.dart';
import '../list/cover_image.dart';

/// 播放列表面板展示模式。
enum QueuePanelStyle {
  /// 右侧滑入侧边栏（播放页用）：面板贴窗口右缘、撑满高度。
  slide,

  /// 锚定浮层（播放条用）：从触发按钮位置紧凑展开，
  /// 动效对齐顶栏账号 PopupMenuButton（淡入 + 轻微弹性放大）。
  popup,
}

/// 播放列表面板（对齐原项目队列；从播放条 / 播放页打开）。
///
/// 展示当前播放队列：当前曲高亮、点击切换、移除、拖拽排序；
/// 顶部提供随机 / 循环模式切换与清空。
/// 交互：毛玻璃面板；播放页走右侧滑入，播放条走锚定浮层。
class QueuePanel extends ConsumerWidget {
  const QueuePanel({
    super.key,
    required this.style,
    required this.width,
    required this.animation,
    this.anchor,
    this.maxHeight,
  });

  /// 展示模式（[QueuePanelStyle.slide] / [QueuePanelStyle.popup]）。
  final QueuePanelStyle style;

  /// 面板锚点（overlay 坐标：left / bottom），popup 模式由 [show] 计算。
  final Offset? anchor;

  /// 面板宽度。
  final double width;

  /// 面板最大高度（popup 模式，避免超出窗口顶边）。
  final double? maxHeight;

  /// 路由入场动画（面板本体的动效在此实现，而非作用于全屏）。
  final Animation<double> animation;

  static Future<void> show(
    BuildContext context, {
    QueuePanelStyle style = QueuePanelStyle.slide,
    Rect? anchor,
  }) {
    final overlaySize = (Overlay.of(context).context.findRenderObject()
            as RenderBox?)
        ?.size ??
        MediaQuery.sizeOf(context);
    const width = 400.0;
    const gap = 8.0; // popup：面板底边到触发按钮顶边的间距
    const margin = 12.0;

    final slide = style == QueuePanelStyle.slide;
    final a = anchor;
    // slide：右缘贴窗口；popup：右缘对齐按钮（窗口边界自动收敛）
    final left = slide
        ? overlaySize.width - width - margin
        : a == null
            ? overlaySize.width - width - margin
            : (a.right - width)
                .clamp(margin, overlaySize.width - width - margin)
                .toDouble();
    // slide：全高留上下边距；popup：从按钮顶部向上展开
    final bottom = slide
        ? margin
        : a == null
            ? 96.0
            : (overlaySize.height - a.top + gap)
                .clamp(margin, overlaySize.height - width)
                .toDouble();
    final maxHeight =
        (overlaySize.height - margin - bottom).clamp(240.0, 560.0).toDouble();

    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: context.l10n.queueTitle,
      // slide（侧边栏）：变暗遮罩；popup：透明遮罩，点击面板外关闭
      // （对齐 PopupMenuButton：无遮罩变暗，点外部即收起）
      barrierColor: slide
          ? Colors.black.withValues(alpha: 0.35)
          : Colors.transparent,
      // 与「更多」PopupMenuButton 同款时长（_kMenuDuration）
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) => QueuePanel(
        style: style,
        anchor: Offset(left, bottom),
        width: width,
        maxHeight: maxHeight,
        animation: animation,
      ),
      // 面板动效在 QueuePanel 内部实现（作用面板本体，对齐「更多」菜单：
      // 原地淡入 + 弹性放大，而非整屏动画）
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          child,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final queue = ref.watch(playbackProvider.select((s) => s.queue));

    final body = _buildBody(context, theme, scheme, ref, queue);
    final glass = _glass(context, child: body);
    // 性能模式（MediaQuery.disableAnimations）：面板直出，无滑入/展开动效
    final noAnim = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    if (style == QueuePanelStyle.slide) {
      // 播放页：右侧滑入侧边栏（面板本体从右侧滑入，遮罩由 barrier 变暗）
      final panel = SizedBox(width: width, child: glass);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Align(
          alignment: Alignment.centerRight,
          child: noAnim
              ? panel
              : SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(1, 0),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                      reverseCurve: Curves.easeInCubic,
                    ),
                  ),
                  child: panel,
                ),
        ),
      );
    }
    // 播放条：锚定浮层——播放条在底部，面板从按钮位置**从下到上**生长：
    // 高度从 0 向上展开（底边锚定按钮）+ 前 1/3 快速淡入。
    // 宽度保持固定（400），不做水平收缩——宽面板从 0 变宽会像"定位错了"，
    // 且 PopupMenu 的宽度展开只因菜单本身窄，不适用于大面板。
    final expand = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final fade = CurveTween(curve: const Interval(0.0, 1.0 / 3.0))
        .animate(animation);
    final panel = ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight!),
      child: glass,
    );
    return Stack(
      children: [
        Positioned(
          left: anchor!.dx,
          bottom: anchor!.dy,
          width: width,
          child: noAnim
              ? panel
              : ClipRect(
                  child: FadeTransition(
                    opacity: fade,
                    child: SizeTransition(
                      sizeFactor: expand,
                      axis: Axis.vertical,
                      alignment: Alignment.bottomCenter, // 从底部（按钮侧）向上展开
                      child: panel,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// 面板主体：头部（标题 + 随机/循环/清空/关闭）+ 队列列表。
  Widget _buildBody(
    BuildContext context,
    ThemeData theme,
    ColorScheme scheme,
    WidgetRef ref,
    List<Track> queue,
  ) {
    final notifier = ref.read(playbackProvider.notifier);
    final l10n = context.l10n;
    // 选择性订阅（播放位置/FFT 50ms 更新不重建队列面板）
    final shuffle = ref.watch(playbackProvider.select((s) => s.shuffle));
    final repeatMode =
        ref.watch(playbackProvider.select((s) => s.repeatMode));
    final queueIndex =
        ref.watch(playbackProvider.select((s) => s.queueIndex));
    final playing = ref.watch(playbackProvider.select((s) => s.playing));

    // slide：列表撑满剩余高度；popup：受 maxHeight 约束内部滚动
    final Widget listArea;
    if (style == QueuePanelStyle.slide) {
      listArea = Expanded(
          child: _buildList(
              context, queue, queueIndex, playing, notifier, scheme));
    } else {
      listArea = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: (maxHeight ?? 400) - 56),
        child: _buildList(
            context, queue, queueIndex, playing, notifier, scheme),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── 头部：标题 + 随机/循环/清空 + 关闭 ──────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 6, 4),
          child: Row(
            children: [
              Icon(Icons.queue_music, size: 19, color: scheme.primary),
              const SizedBox(width: 8),
              Text(l10n.queueTitle, style: theme.textTheme.titleMedium),
              const SizedBox(width: 8),
              if (queue.isNotEmpty)
                Text(
                  l10n.queueTrackCount(queue.length),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              const Spacer(),
              IconButton(
                tooltip: shuffle ? l10n.queueShuffleOff : l10n.queueShuffle,
                onPressed: notifier.toggleShuffle,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.shuffle,
                  size: 19,
                  color: shuffle
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
              ),
              IconButton(
                tooltip: switch (repeatMode) {
                  'list' => l10n.queueRepeatList,
                  'one' => l10n.queueRepeatOne,
                  _ => l10n.queueRepeatMode,
                },
                onPressed: notifier.cycleRepeatMode,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  repeatMode == 'one' ? Icons.repeat_one : Icons.repeat,
                  size: 19,
                  color: scheme.primary,
                ),
              ),
              IconButton(
                tooltip: l10n.queueClear,
                onPressed: queue.isEmpty ? null : notifier.clearQueue,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              ),
              IconButton(
                tooltip: l10n.commonClose,
                onPressed: () => Navigator.of(context).pop(),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // ── 队列列表（拖拽排序）────────────────────────────
        listArea,
      ],
    );
  }

  Widget _buildList(
    BuildContext context,
    List<Track> queue,
    int queueIndex,
    bool playing,
    PlaybackNotifier notifier,
    ColorScheme scheme,
  ) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    if (queue.isEmpty) {
      return SizedBox(
        height: 160,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.playlist_play,
                size: 44,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.35),
              ),
              const SizedBox(height: 10),
              Text(
                l10n.queueEmpty,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              Text(
                l10n.queueEmptyHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      buildDefaultDragHandles: false,
      shrinkWrap: style != QueuePanelStyle.slide,
      proxyDecorator: (child, index, animation) => Material(
        color: Colors.transparent,
        child: child,
      ),
      itemCount: queue.length,
      onReorderItem: (oldIndex, newIndex) =>
          notifier.moveInQueue(oldIndex, newIndex),
      itemBuilder: (context, index) {
        final track = queue[index];
        final current = index == queueIndex;
        return _QueueTile(
          key: ValueKey('${track.source}:${track.id}:$index'),
          track: track,
          index: index,
          current: current,
          playing: current && playing,
          onTap: () => notifier.playAtIndex(index),
          onRemove: () => notifier.removeFromQueue(index),
        );
      },
    );
  }

  /// 毛玻璃面板：blur 背景 + 半透明表面 + 细描边（对齐 macOS 风格浮层）。
  /// 内部叠一层透明 Material：为 IconButton / ListTile 等 Ink 组件
  /// 提供 Material 祖先（否则 Material.of 空断言崩溃）。
  Widget _glass(BuildContext context, {required Widget child}) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.66),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 28,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 队列单行：封面 + 标题/副标题 + 时长 + 拖拽手柄 + 移除。
class _QueueTile extends StatelessWidget {
  const _QueueTile({
    super.key,
    required this.track,
    required this.index,
    required this.current,
    required this.playing,
    required this.onTap,
    required this.onRemove,
  });

  final Track track;
  final int index;
  final bool current;
  final bool playing;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final titleStyle = theme.textTheme.bodyMedium?.copyWith(
      color: current ? scheme.primary : scheme.onSurface,
      fontWeight: current ? FontWeight.w600 : FontWeight.w400,
    );
    final subtitle = track.subtitle.isEmpty
        ? (track.album?.name ?? '')
        : track.subtitle;

    return ListTile(
      dense: true,
      onTap: onTap,
      leading: SizedBox(
        width: 36,
        child: Center(
          child: current
              ? Icon(
                  playing ? Icons.graphic_eq : Icons.play_arrow,
                  size: 18,
                  color: scheme.primary,
                )
              : Text(
                  '${index + 1}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    // 4 位及以上序号缩小字体（上千首队列），保持列宽不溢出
                    fontSize: index >= 999 ? 10.5 : null,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
        ),
      ),
      title: Row(
        children: [
          // 封面
          CoverImage(
            cover: track.cover,
            width: 30,
            height: 30,
            radius: 6,
            iconSize: 16,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(track.title, style: titleStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (track.duration > 0)
            Text(
              formatMs(track.duration),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Icon(
                Icons.drag_indicator,
                size: 18,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
          IconButton(
            tooltip: context.l10n.menuRemoveFromQueue,
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
            icon: Icon(
              Icons.close,
              size: 16,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}
