import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/l10n.dart';
import '../../services/netease/netease_api.dart' show CoverItem;
import '../../services/streaming/streaming_provider.dart';
import '../list/cover_grid.dart';
import 'play_actions.dart';

/// 专辑 Tab：封面网格。
class StreamingAlbumsTab extends ConsumerWidget {
  const StreamingAlbumsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final albums = ref.watch(streamingProvider.select((s) => s.albums));
    final loading = ref.watch(streamingProvider.select((s) => s.loading));

    if (albums.isEmpty && !loading) {
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
        for (final a in albums)
          CoverItem(
            id: a.id,
            title: a.name,
            cover: a.cover,
            subtitle: a.artist ?? '',
            trackCount: a.trackCount ?? 0,
          ),
      ],
      loading: loading,
      onTap: (item) => context.push('/streaming/album/${Uri.encodeComponent(item.id)}'),
      onPlay: (item) {
        final all = albums;
        final idx = all.indexWhere((a) => a.id == item.id);
        if (idx < 0) return;
        playStreamingAlbum(ref, all[idx]);
      },
    );
  }
}
