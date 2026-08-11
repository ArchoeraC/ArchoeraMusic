import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/netease/track.dart';
import '../../stores/app_prefs.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../utils/format.dart';
import 'cover_image.dart';
import '../common/anim.dart';

/// 红心匹配键：酷狗用歌曲 hash（搜索条目 id 退化为 hash、歌单条目可能为
/// audio_id，不统一），网易云用 track.id（与 LikeController 保持一致）。
String songLikeKey(Track t) =>
    t.source == 'kugou' ? (t.kugou?.hash ?? t.id) : t.id;

/// 行高（与 [SongList] 表头高度对齐，行组件内部使用）。
const double _rowHeight = 68.0;

/// 单个歌曲行（悬停态独立管理）。
///
/// 播放中主色高亮 + 边框；悬停显示播放图标覆盖序号；批量模式行内
/// 序号列变勾选框；右键触发 [onContextMenu]；红心按钮可选显示。
class SongRow extends ConsumerStatefulWidget {
  const SongRow({
    super.key,
    required this.item,
    required this.index,
    required this.showIndex,
    required this.showAlbum,
    required this.showDuration,
    required this.showSource,
    required this.isPlaying,
    required this.playingNow,
    required this.liked,
    required this.onPlay,
    this.onToggleLike,
    this.onContextMenu,
    this.batchActive = false,
    this.selected = false,
    this.onToggleSelect,
  });

  final Track item;
  final int index;
  final bool showIndex;
  final bool showAlbum;
  final bool showDuration;
  final bool showSource;
  final bool isPlaying;
  final bool playingNow;
  final bool liked;
  final ValueChanged<Track> onPlay;
  final Future<void> Function(Track)? onToggleLike;
  final void Function(Track, Offset)? onContextMenu;

  /// 批量选择模式（行内序号列变勾选框，行点击切换选择）。
  final bool batchActive;
  final bool selected;
  final VoidCallback? onToggleSelect;

  @override
  ConsumerState<SongRow> createState() => _SongRowState();
}

class _SongRowState extends ConsumerState<SongRow> {
  bool _hover = false;

  /// 行背景：播放中主色高亮 → 批量模式已选浅色 → 悬停浅底 → 透明。
  Color _rowColor(Color primary) {
    if (widget.isPlaying) return primary.withValues(alpha: 0.14);
    if (widget.batchActive && widget.selected) {
      return primary.withValues(alpha: 0.08);
    }
    if (_hover) {
      return Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05);
    }
    return Colors.transparent;
  }

  /// 行边框：播放中主色边框 → 批量模式已选弱边框 → 悬停弱化边框 → 透明。
  Color _rowBorder(Color primary) {
    if (widget.isPlaying) return primary.withValues(alpha: 0.4);
    if (widget.batchActive && widget.selected) {
      return primary.withValues(alpha: 0.3);
    }
    if (_hover) return primary.withValues(alpha: 0.2);
    return Colors.transparent;
  }

  /// 列表副标题文本：歌手 + 可选别名；别名隐藏时仅显示歌手（空则回退）。
  String _subtitleText(AppPrefs prefs, AppLocalizations l10n) {
    final text = prefs.showSubtitle
        ? widget.item.subtitle
        : widget.item.artistNames;
    return text.isEmpty ? l10n.commonUnknownArtist : text;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final item = widget.item;
    final isPlaying = widget.isPlaying;
    final primary = theme.colorScheme.primary;
    // 强迫症预设：列表标签与副标题显示开关（对齐原项目 preset）
    final prefs = ref.watch(appPrefsProvider);
    final bestQuality = _bestQuality(item, l10n);

    return Listener(
      // 右键 → 自绘上下文菜单（PointerEvent.position 为全局坐标）
      onPointerDown: (e) {
        if (widget.onContextMenu != null &&
            (e.buttons & kSecondaryMouseButton) != 0) {
          widget.onContextMenu!(item, e.position);
        }
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            // 批量模式：行点击切换选择（不做播放）
            onTap: widget.batchActive
                ? widget.onToggleSelect
                : () => widget.onPlay(item),
            child: AnimatedContainer(
              duration: animDuration(
                context,
                const Duration(milliseconds: 150),
              ),
              height: _rowHeight,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: _rowColor(primary),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _rowBorder(primary)),
              ),
              child: Row(
                children: [
                  // 批量模式：序号列变勾选框；否则保留原序号/播放态
                  if (widget.batchActive)
                    SizedBox(
                      width: 32,
                      child: _SelectCell(
                        selected: widget.selected,
                        onTap: widget.onToggleSelect ?? () {},
                      ),
                    )
                  else if (widget.showIndex)
                    SizedBox(
                      width: 32,
                      child: _IndexCell(
                        index: widget.index,
                        isPlaying: isPlaying,
                        playingNow: widget.playingNow,
                        hover: _hover,
                        onPlay: () => widget.onPlay(item),
                      ),
                    ),
                  // 信息：封面 + 标题 + 歌手
                  Expanded(
                    child: Row(
                      children: [
                        CoverImage(cover: item.cover),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  if (widget.showSource)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 6),
                                      child: _SourceBadge(source: item.source),
                                    ),
                                  // 付费角标（VIP / EP；强迫症预设可隐藏）
                                  if (!prefs.hideVipTag && item.fee > 0)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 6),
                                      child: _Badge(
                                        label: item.fee == 1 ? 'VIP' : 'EP',
                                        textColor: const Color(0xFFE55B5B),
                                        borderColor: const Color(
                                          0xFFE55B5B,
                                        ).withValues(alpha: 0.4),
                                      ),
                                    ),
                                  // 原唱角标（酷狗 IsOriginal；跟随音质标签开关）
                                  if (!prefs.hideQualityTag && item.isOriginal)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 6),
                                      child: _Badge(
                                        label: l10n.commonOriginal,
                                        textColor: Colors.white,
                                        background: theme.colorScheme.primary,
                                      ),
                                    ),
                                  // 音质角标（酷狗 hash 链 / 网易云 quality；
                                  // 无损档琥珀色高亮，对齐 SPlayer-Next）
                                  if (!prefs.hideQualityTag &&
                                      bestQuality != null)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 6),
                                      child: _Badge(
                                        label: bestQuality.label,
                                        textColor: bestQuality.lossless
                                            ? const Color(0xFFFFB300)
                                            : theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                        background: bestQuality.lossless
                                            ? const Color(
                                                0xFFFFB300,
                                              ).withValues(alpha: 0.12)
                                            : theme.colorScheme.onSurface
                                                  .withValues(alpha: 0.08),
                                        borderColor: bestQuality.lossless
                                            ? const Color(
                                                0xFFFFB300,
                                              ).withValues(alpha: 0.45)
                                            : null,
                                      ),
                                    ),
                                  Flexible(
                                    child: Text(
                                      item.title,
                                      style: theme.textTheme.bodyLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.w500,
                                            color: isPlaying ? primary : null,
                                          ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                // 副标题：歌手 + 可选别名（强迫症预设控制）
                                _subtitleText(prefs, l10n),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: isPlaying
                                      ? primary.withValues(alpha: 0.7)
                                      : theme.colorScheme.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 专辑
                  if (widget.showAlbum)
                    Expanded(
                      child: Text(
                        item.album?.name.isNotEmpty == true
                            ? item.album!.name
                            : l10n.commonUnknownAlbum,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: isPlaying
                              ? primary.withValues(alpha: 0.7)
                              : theme.colorScheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  const SizedBox(width: 28),
                  // 时长
                  if (widget.showDuration)
                    SizedBox(
                      width: 64,
                      child: Text(
                        formatMs(item.duration),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: isPlaying
                              ? primary.withValues(alpha: 0.6)
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  // 红心（可选：喜欢页 / 收藏场景展示）
                  if (widget.onToggleLike != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: _LikeButton(
                        liked: widget.liked,
                        onTap: () => widget.onToggleLike!(item),
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
}

/// 行内红心切换按钮（填充红 = 已喜欢；点击不冒泡到行播放）。
class _LikeButton extends StatelessWidget {
  const _LikeButton({required this.liked, required this.onTap});

  final bool liked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: liked ? context.l10n.commonUnlike : context.l10n.commonLike,
      child: InkResponse(
        radius: 18,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: AnimatedSwitcher(
            duration: animDuration(context, const Duration(milliseconds: 180)),
            transitionBuilder: (child, animation) =>
                ScaleTransition(scale: animation, child: child),
            child: Icon(
              liked ? Icons.favorite : Icons.favorite_border,
              key: ValueKey(liked),
              size: 17,
              color: liked
                  ? Colors.redAccent
                  : scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }
}

/// 序号 / 播放状态单元格：数字（悬停显示播放图标）→ 播放中显示音符图标。
class _IndexCell extends StatelessWidget {
  const _IndexCell({
    required this.index,
    required this.isPlaying,
    required this.playingNow,
    required this.hover,
    required this.onPlay,
  });

  final int index;
  final bool isPlaying;
  final bool playingNow;
  final bool hover;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final Widget base;
    if (isPlaying) {
      base = Icon(
        playingNow ? Icons.graphic_eq : Icons.music_note,
        size: 18,
        color: primary,
      );
    } else {
      base = Text(
        '${index + 1}',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyMedium?.copyWith(
          // 4 位及以上序号缩小字体（如「我喜欢」上千首），
          // 保持序号列固定宽度不溢出
          fontSize: index >= 999 ? 11 : null,
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    // 悬停：覆盖播放按钮
    return Stack(
      alignment: Alignment.center,
      children: [
        AnimatedOpacity(
          duration: animDuration(context, const Duration(milliseconds: 150)),
          opacity: hover ? 0 : 1,
          child: base,
        ),
        AnimatedOpacity(
          duration: animDuration(context, const Duration(milliseconds: 150)),
          opacity: hover ? 1 : 0,
          child: Icon(
            isPlaying && playingNow ? Icons.pause : Icons.play_arrow,
            size: 18,
            color: primary,
          ),
        ),
        // 整个单元格可点击播放
        Positioned.fill(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(onTap: onPlay),
          ),
        ),
      ],
    );
  }
}

/// 批量模式下的勾选单元格（圆形勾选框；点击不冒泡到行播放）。
class _SelectCell extends StatelessWidget {
  const _SelectCell({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Tooltip(
        message: selected
            ? context.l10n.batchSelectAll
            : context.l10n.batchInvert,
        child: InkResponse(
          radius: 18,
          onTap: onTap,
          child: AnimatedContainer(
            duration: animDuration(context, const Duration(milliseconds: 150)),
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? scheme.primary : Colors.transparent,
              border: Border.all(
                color: selected
                    ? scheme.primary
                    : scheme.outline.withValues(alpha: 0.6),
                width: 1.5,
              ),
            ),
            child: selected
                ? Icon(Icons.check, size: 12, color: scheme.onPrimary)
                : null,
          ),
        ),
      ),
    );
  }
}

/// 来源平台小徽标（对齐 SPlayer-Next 列表的平台角标；聚合搜索时区分来源）。
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (source) {
      'netease' => ('云', const Color(0xFFC20C0C)),
      // 酷狗徽标为蓝底白字
      'kugou' => ('酷', const Color(0xFF00A7E0)),
      _ => ('', Colors.transparent),
    };
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      width: 16,
      height: 16,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          height: 1,
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 可用最高音质标签（label + 是否无损档）：
/// - 酷狗：按 hash 链判断（Hi-Res/无损/HQ/SQ/LQ，见 KugouTrackInfo）；
/// - 网易云：由 [Track.quality] 反推等级（对齐 SPlayer-Next quality.ts）。
/// 返回 null 表示无可用信息（列表不显示音质标签）。
({String label, bool lossless})? _bestQuality(Track t, AppLocalizations l10n) {
  final k = t.kugou;
  if (k != null) {
    if (k.hashFor('hi-res') != null) return (label: 'Hi-Res', lossless: true);
    if (k.hashFor('lossless') != null) {
      return (label: l10n.commonLossless, lossless: true);
    }
    if (k.hashFor('hq') != null) return (label: 'HQ', lossless: false);
    if (k.hashFor('sq') != null) return (label: 'SQ', lossless: false);
    if (k.hashFor('lq') != null) return (label: 'LQ', lossless: false);
    return null;
  }
  return _qualityLevel(t.quality, l10n);
}

/// 由 [TrackQuality] 反推等级短码（对齐 SPlayer-Next quality.ts 的
/// getQualityLevel/getQualityLabel）：无损编解码器 → Hi-Res（sr≥96k 且
/// 24bit）/ 无损；否则按 bitrate 分档（≥320k HQ / ≥192k SQ / LQ）。
({String label, bool lossless})? _qualityLevel(
  TrackQuality? q,
  AppLocalizations l10n,
) {
  if (q == null || q.codec.isEmpty || q.codec == 'unknown') return null;
  const losslessCodecs = {
    'flac',
    'alac',
    'ape',
    'wav',
    'aiff',
    'wavpack',
    'tta',
  };
  if (losslessCodecs.contains(q.codec.toLowerCase())) {
    if (q.sampleRate >= 96000 && q.bitsPerSample >= 24) {
      return (label: 'Hi-Res', lossless: true);
    }
    return (label: l10n.commonLossless, lossless: true);
  }
  final kbps = q.bitRate / 1000;
  if (kbps >= 320) return (label: 'HQ', lossless: false);
  if (kbps >= 192) return (label: 'SQ', lossless: false);
  return (label: 'LQ', lossless: false);
}

/// 文本小徽标（付费 / 音质角标共用：圆角底 + 小字标签）。
class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.textColor,
    this.background,
    this.borderColor,
  });

  final String label;
  final Color textColor;
  final Color? background;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: background,
        border: borderColor == null ? null : Border.all(color: borderColor!),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9.5,
          height: 1,
          fontWeight: FontWeight.w600,
          color: textColor,
        ),
      ),
    );
  }
}
