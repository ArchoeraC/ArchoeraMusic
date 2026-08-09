/// 通用在线曲目右键菜单（搜索 / 我喜欢 / 历史 / 歌单详情等共用）。
///
/// 菜单项：播放 / 下一首播放 / 收藏切换 / 查看评论（在线曲目）+
/// 页面专属 [extra]。页面可通过 [onToggleLike] 定制收藏行为
/// （如「我喜欢」页取消收藏时从列表移除该行）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/apis/runtime.dart';
import '../../core/downloader/download_controller.dart';
import '../../core/netease/track.dart';
import '../../core/playback/playback_notifier.dart';
import '../../core/state/app_prefs.dart';
import '../../core/state/providers.dart';
import '../../l10n/l10n.dart';
import 'comment_dialog.dart';
import 'kugou_login_button.dart';
import 'netease_login_dialog.dart';
import 's_context_menu.dart';
import 'toast.dart';

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
        SContextMenuItem(
          label: l10n.menuDownload,
          icon: Icons.download_outlined,
          onTap: () => _startDownload(context, ref, track),
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
  if (!await _ensureLoggedIn(context, ref, track.source)) return;
  if (!context.mounted) return;
  final l10n = context.l10n;
  final defaultQuality = ref.read(appPrefsProvider).downloadQuality;
  final quality = await _pickDownloadQuality(context, defaultQuality);
  if (quality == null || !context.mounted) return;
  final controller = ref.read(downloadControllerProvider.notifier);
  final taskId = controller.enqueue(track, quality: quality);
  if (taskId != null) {
    toast(l10n.toastAddedToDownloadQueue(l10nQualityLabel(l10n, quality)));
  } else {
    toast(l10n.toastDownloadEngineNotReady);
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
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      final l10n = ctx.l10n;
      return AlertDialog(
        icon: Icon(Icons.lock_outline, color: scheme.onSurfaceVariant),
        title: Text(l10n.downloadRequiresLoginTitle),
        content: Text(
          l10n.downloadRequiresLoginContent(platform),
          style: TextStyle(
            fontSize: 13,
            color: scheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.commonGoLogin),
          ),
        ],
      );
    },
  );
  return go ?? false;
}

/// 下载音质选择（Hi-Res → 无损 → HQ → SQ → LQ；[defaultQuality] 档标「默认」）。
Future<String?> _pickDownloadQuality(
  BuildContext context,
  String defaultQuality,
) {
  final levels = downloadQualityLevels;
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      final l10n = ctx.l10n;
      return AlertDialog(
        title: Text(l10n.downloadQualityTitle),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: SizedBox(
          width: 260,
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
                  onTap: () => Navigator.pop(ctx, l),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.commonCancel),
          ),
        ],
      );
    },
  );
}
