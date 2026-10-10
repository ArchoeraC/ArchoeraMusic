// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 「添加到歌单」选择器（网易云，对齐原项目 PlaylistPickerDialog.vue）。
///
/// 列出当前用户**自建**歌单（排除「我喜欢的音乐」与 [excludeId]），点选即加入；
/// 顶部「新建歌单」可先建后加。加入数量按服务端确认数提示，0 视为已存在。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../services/netease/track.dart';
import '../../services/source/media_request_headers.dart';
import '../../stores/netease_user_playlists.dart';
import '../../stores/providers.dart';
import '../common/toast.dart';
import '../player/s_controls.dart';
import 'netease_login_dialog.dart';
import 'playlist_create_dialog.dart';
import 's_dialog.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';

/// 弹出「添加到歌单」选择器。
///
/// [tracks] 为待加入的曲目（仅 [Track.source] == 'netease' 的会被加入）；
/// [excludeId] 用于从某个歌单内部加入时排除该歌单自身。
Future<void> showPlaylistPickerDialog(
  BuildContext context, {
  required List<Track> tracks,
  String? excludeId,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    useRootNavigator: false,
    builder: (_) => _PlaylistPickerDialog(tracks: tracks, excludeId: excludeId),
  );
}

class _PlaylistPickerDialog extends ConsumerStatefulWidget {
  const _PlaylistPickerDialog({required this.tracks, this.excludeId});

  final List<Track> tracks;
  final String? excludeId;

  @override
  ConsumerState<_PlaylistPickerDialog> createState() =>
      _PlaylistPickerDialogState();
}

class _PlaylistPickerDialogState extends ConsumerState<_PlaylistPickerDialog> {
  bool _busy = false;

  List<String> get _trackIds => [
    for (final t in widget.tracks)
      if (t.source == 'netease' && t.id.isNotEmpty) t.id,
  ];

  @override
  void initState() {
    super.initState();
    if (ref.read(neteaseAuthProvider) != null) {
      ref.read(neteaseUserPlaylistsProvider.notifier).ensureLoaded();
    }
  }

  Future<void> _addTo(String playlistId) async {
    if (_busy) return;
    final ids = _trackIds;
    if (ids.isEmpty) return;
    setState(() => _busy = true);
    try {
      final count = await ref
          .read(neteaseUserPlaylistsProvider.notifier)
          .addTracks(playlistId, ids);
      if (!mounted) return;
      toast(
        (count == null || count > 0)
            ? context.l10n.playlistAdded(count: ids.length)
            : context.l10n.playlistAlreadyIn,
      );
      Navigator.of(context).pop();
    } catch (_) {
      if (mounted) toast(context.l10n.playlistAddFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createAndAdd() async {
    final id = await showPlaylistCreateDialog(context, quietSubmit: true);
    if (id == null || !mounted) return;
    await _addTo(id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final loggedIn = ref.watch(neteaseAuthProvider) != null;
    return SDialog(
      title: l10n.playlistPickTitle,
      width: 460,
      maxContentHeight: 380,
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
      ],
      child: loggedIn ? _buildList(context) : _buildLoginPrompt(context),
    );
  }

  Widget _buildLoginPrompt(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        Icon(EtaIcons.alertOutline, color: scheme.onSurfaceVariant),
        const SizedBox(height: 10),
        Text(
          l10n.toastLoginRequiredNetease,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 14),
        SButton(
          label: l10n.commonGoLogin,
          variant: SButtonVariant.primary,
          onPressed: () async {
            await showNeteaseLoginDialog(context);
            if (mounted) {
              ref.read(neteaseUserPlaylistsProvider.notifier).refresh();
            }
          },
        ),
      ],
    );
  }

  Widget _buildList(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final store = ref.watch(neteaseUserPlaylistsProvider);
    final liked = store.likedPlaylistId;
    final items = [
      for (final p in store.created)
        if (p.id != liked && p.id != widget.excludeId) p,
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _NewPlaylistRow(
          label: l10n.playlistPickNew,
          onTap: _busy ? null : _createAndAdd,
        ),
        const Divider(height: 1),
        if (!store.loaded && store.loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
            child: Column(
              children: [
                Icon(
                  EtaIcons.playlist,
                  size: 34,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 10),
                Text(
                  l10n.playlistPickEmpty,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.playlistPickEmptyHint,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          )
        else
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: items.length,
              itemBuilder: (context, i) => _PlaylistPickRow(
                playlist: items[i],
                onTap: _busy ? null : () => _addTo(items[i].id),
              ),
            ),
          ),
      ],
    );
  }
}

class _NewPlaylistRow extends StatelessWidget {
  const _NewPlaylistRow({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(EtaIcons.add, color: scheme.onPrimaryContainer),
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistPickRow extends StatelessWidget {
  const _PlaylistPickRow({required this.playlist, this.onTap});

  final PlaylistItem playlist;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final cover = playlist.cover;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 44,
                height: 44,
                child: cover == null || cover.isEmpty
                    ? Container(
                        color: theme.colorScheme.primaryContainer.withValues(
                          alpha: 0.5,
                        ),
                        child: Icon(
                          EtaIcons.music,
                          color: theme.colorScheme.primary,
                        ),
                      )
                    : Image.network(
                        cover,
                        fit: BoxFit.cover,
                        headers: mediaHeadersForUrl(cover),
                        errorBuilder: (_, _, _) => Container(
                          color: theme.colorScheme.primaryContainer.withValues(
                            alpha: 0.5,
                          ),
                          child: Icon(
                            EtaIcons.music,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n.commonTrackCount(count: playlist.trackCount),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
