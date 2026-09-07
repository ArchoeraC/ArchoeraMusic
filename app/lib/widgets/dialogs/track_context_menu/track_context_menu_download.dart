// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../track_context_menu.dart';

Future<void> downloadTracks(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks,
) async {
  final l10nQq = context.l10n;
  final online = tracks
      .where((t) => t.source == 'netease' || t.source == 'kugou')
      .toList();
  final qqCount = tracks.where((t) => t.source == 'qqmusic').length;
  if (qqCount > 0) {
    if (online.isEmpty) {
      toast(l10nQq.qqMusicDownloadUnsupported);
      return;
    }
    toast(l10nQq.qqMusicDownloadSkipped(qqCount));
  }
  if (online.isEmpty) return;
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
      final enriched = await ref
          .read(kugouApiProvider)
          .enrichKugouHashes(target);
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
