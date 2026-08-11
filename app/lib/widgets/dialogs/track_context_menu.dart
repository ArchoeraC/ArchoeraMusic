/// 通用在线曲目右键菜单（搜索 / 我喜欢 / 历史 / 歌单详情等共用）。
///
/// 菜单项：播放 / 下一首播放 / 收藏切换 / 查看评论（在线曲目）+
/// 页面专属 [extra]。页面可通过 [onToggleLike] 定制收藏行为
/// （如「我喜欢」页取消收藏时从列表移除该行）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../apis/runtime.dart';
import '../../services/downloader/download_controller.dart';
import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../stores/app_prefs.dart';
import '../../stores/providers.dart';
import '../../l10n/l10n.dart';
import 'comment_dialog.dart';
import '../common/glass_surface.dart';
import 'kugou_login_button.dart';
import 'netease_login_dialog.dart';
import 's_context_menu.dart';
import 's_dialog.dart';
import 'track_detail_dialog.dart';
import '../common/toast.dart';

/// 弹出通用曲目右键菜单。
void showTrackContextMenu(
  BuildContext context, {
  required WidgetRef ref,
  required Track track,
  required Offset position,
  required VoidCallback onPlay,
  Future<void> Function(Track track)? onToggleLike,
  List<SContextMenuItem> extra = const [],
}) {
  final isOnline = track.source == 'netease' || track.source == 'kugou';
  final liked = ref.read(likeControllerProvider).isLiked(track);
  final toggle =
      onToggleLike ?? (t) => _defaultToggleLike(context, ref, t);
  final l10n = context.l10n;

  SContextMenu.show(
    context,
    position: position,
    items: [
      SContextMenuItem(
        label: l10n.menuPlay,
        icon: Icons.play_arrow,
        onTap: onPlay,
      ),
      SContextMenuItem(
        label: l10n.menuPlayNext,
        icon: Icons.skip_next_outlined,
        onTap: () {
          ref.read(playbackProvider.notifier).insertToQueue(track);
          toast(l10n.toastAddedToQueue);
        },
      ),
      if (isOnline) ...[
        SContextMenuItem.divider(),
        SContextMenuItem(
          label: liked ? l10n.menuUnlike : l10n.menuLike,
          icon: liked ? Icons.favorite : Icons.favorite_outline,
          onTap: () => toggle(track),
        ),
        SContextMenuItem(
          label: l10n.menuComment,
          icon: Icons.chat_bubble_outline,
          onTap: () => showCommentDialog(context, track: track),
        ),
        // 下载接口仅在开发者模式开启后显示（设置-关于长按版本开启）
        if (ref.read(appPrefsProvider).developerMode)
          SContextMenuItem(
            label: l10n.menuDownload,
            icon: Icons.download_outlined,
            onTap: () => _startDownload(context, ref, track),
          ),
        SContextMenuItem.divider(),
        SContextMenuItem(
          label: l10n.menuTrackDetail,
          icon: Icons.info_outline,
          onTap: () => showTrackDetailDialog(context, track: track),
        ),
      ],
      ...extra,
    ],
  );
}

/// 默认收藏切换：双平台红心 + 结果 toast（失败提示登录）。
Future<void> _defaultToggleLike(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  final controller = ref.read(likeControllerProvider);
  final ok = await controller.toggle(track);
  if (!context.mounted) return;
  final l10n = context.l10n;
  if (!ok) {
    toast(track.source == 'kugou'
        ? l10n.toastLoginRequiredKugou
        : l10n.toastLoginRequiredNetease);
    return;
  }
  toast(controller.isLiked(track) ? l10n.toastLiked : l10n.toastUnliked);
}

/// 开始下载：先确认登录态（下载强制需登录），再选音质，最后入队。
Future<void> _startDownload(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  if (track.source == 'kugou' && track.kugou == null) {
    toast(context.l10n.toastNoQualityInfo);
    return;
  }
  await downloadTracks(context, ref, [track]);
}

/// 批量下载（列表批量操作栏 / 单曲下载共用）：
/// 登录校验 + 一次音质选择 + 逐首入队。
///
/// 仅处理在线曲目（网易云/酷狗；无下载接口的本地/流媒体曲目跳过）；
/// 酷狗曲目下载前补齐 hash 链（历史/收藏等旧入口的 Track 可能只有 128k
/// hash，直接下载会被静默降级；补全后能拿到最高可用音质）。
Future<void> downloadTracks(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks,
) async {
  final online = tracks
      .where((t) => t.source == 'netease' || t.source == 'kugou')
      .toList();
  if (online.isEmpty) return;
  // 批量曲目可能混平台：任一平台未登录都拦截（提示登录对应平台）
  for (final src in const ['kugou', 'netease']) {
    if (online.any((t) => t.source == src)) {
      if (!await _ensureLoggedIn(context, ref, src)) return;
    }
  }
  if (!context.mounted) return;
  final l10n = context.l10n;
  final defaultQuality = ref.read(appPrefsProvider).downloadQuality;
  final quality = await _pickDownloadQuality(context, defaultQuality);
  if (quality == null || !context.mounted) return;
  final controller = ref.read(downloadControllerProvider.notifier);
  var ok = 0;
  for (final t in online) {
    if (!context.mounted) return;
    var target = t;
    if (t.source == 'kugou' && t.kugou != null) {
      final enriched = await ref.read(kugouApiProvider).enrichKugouHashes(target);
      if (enriched != null) target = enriched;
    }
    if (controller.enqueue(target, quality: quality) != null) ok++;
  }
  if (context.mounted) {
    if (ok > 1) {
      toast(l10n.toastBatchAddedToDownloadQueue(ok));
    } else if (ok == 1) {
      toast(l10n.toastAddedToDownloadQueue(l10nQualityLabel(l10n, quality)));
    } else {
      toast(l10n.toastDownloadEngineNotReady);
    }
  }
}

/// 下载前置登录检查（Kugou / Netease 获取下载链接必须带登录态）。
///
/// 未登录时弹提示对话框，「去登录」打开对应扫码登录弹窗；
/// 登录成功后返回 true 继续下载流程（Kugou 以弹窗返回值判定，
/// Netease 以登录后 cookie 是否落盘判定）。其他平台不拦截。
Future<bool> _ensureLoggedIn(
  BuildContext context,
  WidgetRef ref,
  String source,
) async {
  if (source == 'kugou') {
    final s = ref.read(kugouApiProvider).session;
    if (s != null && s.userid.isNotEmpty && s.token.isNotEmpty) return true;
    if (!context.mounted) return false;
    final go = await _showLoginPrompt(context, context.l10n.brandKugou);
    if (!go || !context.mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      barrierDismissible: false,
      builder: (_) => const KgQrLoginDialog(),
    );
    return ok == true;
  }
  if (source == 'netease') {
    if (getRuntime().sessionStore.get('netease').isNotEmpty) return true;
    if (!context.mounted) return false;
    final go = await _showLoginPrompt(context, context.l10n.brandNetease);
    if (!go || !context.mounted) return false;
    await showNeteaseLoginDialog(context);
    return getRuntime().sessionStore.get('netease').isNotEmpty;
  }
  return true;
}

/// 未登录提示：说明下载强制需登录，提供「去登录」入口。
Future<bool> _showLoginPrompt(BuildContext context, String platform) async {
  final go = await showDialog<bool>(
    context: context,
    useRootNavigator: false,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      final l10n = ctx.l10n;
      // Dialog 透明根 + GlassDialogSurface 只包内容（对齐 SDialog）：
      // GlassDialogSurface 若作 pageBuilder 根会铺满窗口成「全遮罩」。
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 48),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
        child: GlassDialogSurface(
          radius: BorderRadius.circular(16),
          color: Theme.of(ctx).dialogTheme.backgroundColor ??
              Theme.of(ctx).colorScheme.surfaceContainerLow,
          child: SizedBox(
            width: 400,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lock_outline,
                          size: 20, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.downloadRequiresLoginTitle,
                          style: Theme.of(ctx).dialogTheme.titleTextStyle,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.downloadRequiresLoginContent(platform),
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(l10n.commonCancel),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(l10n.commonGoLogin),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
  return go ?? false;
}

/// 下载音质选择（Hi-Res → 无损 → HQ → SQ → LQ；[defaultQuality] 档标「默认」）。
///
/// 用 [SDialog.show]（`Dialog` 透明根 + barrier 全局变暗）：若把
/// [GlassDialogSurface]（不透明 ColoredBox）直接当 `showDialog` 的
/// pageBuilder 根包住 [AlertDialog]，`AlertDialog` 内部 `Center` 会撑满
/// 窗口，面板跟着铺满全屏，变成「全遮罩」而非「全局变暗」。
Future<String?> _pickDownloadQuality(
  BuildContext context,
  String defaultQuality,
) {
  final levels = downloadQualityLevels;
  final scheme = Theme.of(context).colorScheme;
  final l10n = context.l10n;
  return SDialog.show<String>(
    context,
    title: l10n.downloadQualityTitle,
    width: 340,
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(l10n.commonCancel),
      ),
    ],
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final l in levels)
          ListTile(
            dense: true,
            leading: Icon(
              l == 'hi-res' || l == 'lossless'
                  ? Icons.high_quality_outlined
                  : Icons.music_note_outlined,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            title: Text(l10nQualityLabel(l10n, l)),
            trailing: l == defaultQuality
                ? Text(
                    l10n.commonDefault,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.primary.withValues(alpha: 0.7),
                    ),
                  )
                : null,
            onTap: () => Navigator.pop(context, l),
          ),
      ],
    ),
  );
}
