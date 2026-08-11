import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/l10n.dart';
import '../../services/netease/netease_api.dart' show CoverItem;
import '../../services/streaming/streaming_provider.dart';
import '../list/cover_grid.dart';
import 'play_actions.dart';

/// 歌单 Tab：封面网格。
class StreamingPlaylistsTab extends ConsumerWidget {
  const StreamingPlaylistsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final playlists = ref.watch(streamingProvider.select((s) => s.playlists));
    final loading = ref.watch(streamingProvider.select((s) => s.loading));

    if (playlists.isEmpty && !loading) {
      return Center(
        child: Text(
          l10n.streamingEmptyNoResults,
          style: TextStyle(
            fontSize: 13,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
        ),
      );
    }
    return CoverGrid(
      items: [
        for (final p in playlists)
          CoverItem(
            id: p.id,
            title: p.name,
            cover: p.cover,
            subtitle: p.owner ?? '',
            trackCount: p.trackCount ?? 0,
          ),
      ],
      loading: loading,
      onTap: (item) =>
          context.push('/streaming/playlist/${Uri.encodeComponent(item.id)}'),
      onPlay: (item) {
        final all = playlists;
        final idx = all.indexWhere((p) => p.id == item.id);
        if (idx < 0) return;
        playStreamingPlaylist(ref, all[idx]);
      },
    );
  }
}
