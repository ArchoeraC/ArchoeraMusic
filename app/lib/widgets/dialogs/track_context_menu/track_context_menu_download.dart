// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../track_context_menu.dart';

Future<void> downloadTracks(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks,
) async {
  // 支持的下载来源：KG/NT（Rust 自研解析）+ QQMusic/Neko/流媒体（Dart 播放管线回退）。
  // Neko 音频直链公开、无需登录；流媒体直链由 Dart 侧带鉴权生成（format=raw 原文件）。
  final online = tracks
      .where(
        (t) =>
            t.source == 'netease' ||
            t.source == 'kugou' ||
            t.source == 'qqmusic' ||
            t.source == 'neko' ||
            t.source == 'streaming',
      )
      .toList();
  if (online.isEmpty) return;
  // 流媒体下载提示（可「不再提示」）：源可由使用者自行保证访问/自建，长期下载到本地
  // 并不划算。右键菜单不提供流媒体下载入口，仅批量（歌单/专辑/多选）触发本提示。
  final hasStreaming = online.any((t) => t.source == 'streaming');
  if (hasStreaming &&
      !ref.read(appPrefsProvider).downloadStreamingNoticeDismissed) {
    final proceed = await _confirmStreamingDownload(context, ref);
    if (!proceed || !context.mounted) return;
  }
  // 仅 KG/NT 强制登录（QQ 免费曲免登录；VIP 曲解析失败由任务错误呈现）。
  for (final src in const ['kugou', 'netease']) {
    if (online.any((t) => t.source == src)) {
      if (!await _ensureLoggedIn(context, ref, src)) return;
    }
  }
  if (!context.mounted) return;
  final l10n = context.l10n;
  final defaultQuality = ref.read(appPrefsProvider).downloadQuality;
  // 直传/流媒体无音质档（Neko 原文件；流媒体服务端 format=raw 原文件）：
  // 整批均为直传源时跳过音质选择，直接用默认。
  final directOnly = online.every(
    (t) => t.source == 'neko' || t.source == 'streaming',
  );
  final quality = directOnly
      ? defaultQuality
      : await _pickDownloadQuality(context, defaultQuality);
  if (quality == null || !context.mounted) return;
  final controller = ref.read(downloadControllerProvider.notifier);
  // 引擎按需加载：入队前确保引擎就绪（首次入队可能尚未加载）。
  await controller.ensureEngine();
  if (!context.mounted) return;
  var ok = 0;
  for (final t in online) {
    if (!context.mounted) return;
    var target = t;
    if (t.source == 'kugou' && t.kugou != null) {
      final enriched = await ref
          .read(kugouApiProvider)
          .enrichKugouHashes(target);
      if (enriched != null) target = enriched;
    } else if (t.source == 'neko') {
      // Neko 元数据不规范：入队前用其它音源补充/重写（标签与文件名受益），
      // 并强制重写歌词（Neko 内嵌/平台歌词常为站点广告）。
      target = await ref
          .read(nekoMetadataEnricherProvider)
          .enrich(target, fetchLyrics: true);
    }
    if (controller.enqueue(target, quality: quality) != null) ok++;
  }
  if (context.mounted) {
    if (ok > 1) {
      toast(l10n.toastBatchAddedToDownloadQueue(count: ok));
    } else if (ok == 1) {
      toast(l10n.toastAddedToDownloadQueue(quality: l10nQualityLabel(l10n, quality)));
    } else {
      toast(l10n.toastDownloadEngineNotReady);
    }
  }
}

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

Future<bool> _showLoginPrompt(BuildContext context, String platform) async {
  final go = await showDialog<bool>(
    context: context,
    useRootNavigator: false,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      final l10n = ctx.l10n;
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 48),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: GlassDialogSurface(
          radius: BorderRadius.circular(16),
          color:
              Theme.of(ctx).dialogTheme.backgroundColor ??
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
                      Icon(
                        EtaIcons.lockOutline,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
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
                    l10n.downloadRequiresLoginContent(platform: platform),
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
                  ? EtaIcons.highQualityOutline
                  : EtaIcons.musicOutline,
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

/// 流媒体下载提示（含「不再提示」）。确认返回 true；勾选不再提示后持久化。
Future<bool> _confirmStreamingDownload(
  BuildContext context,
  WidgetRef ref,
) async {
  final l10n = context.l10n;
  var dontAsk = false;
  final ok = await SDialog.show<bool>(
    context,
    title: l10n.downloadStreamingWarnTitle,
    width: 440,
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: Text(l10n.commonCancel),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, true),
        child: Text(l10n.downloadStreamingWarnProceed),
      ),
    ],
    child: StatefulBuilder(
      builder: (ctx, setState) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.downloadStreamingWarnBody,
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: Theme.of(ctx).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          CheckboxListTile(
            value: dontAsk,
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(l10n.downloadStreamingWarnDontAsk),
            onChanged: (v) => setState(() => dontAsk = v ?? false),
          ),
        ],
      ),
    ),
  );
  if (ok == true && dontAsk) {
    ref
        .read(appPrefsProvider.notifier)
        .setDownloadStreamingNoticeDismissed(true);
  }
  return ok == true;
}
