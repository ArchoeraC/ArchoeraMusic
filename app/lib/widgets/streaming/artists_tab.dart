import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/l10n.dart';
import '../../services/netease/netease_api.dart' show CoverItem;
import '../../services/streaming/streaming_provider.dart';
import '../list/cover_grid.dart';

/// 歌手 Tab：圆形头像网格。
class StreamingArtistsTab extends ConsumerWidget {
  const StreamingArtistsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final artists = ref.watch(streamingProvider.select((s) => s.artists));
    final loading = ref.watch(streamingProvider.select((s) => s.loading));

    if (artists.isEmpty && !loading) {
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
        for (final a in artists)
          CoverItem(
            id: a.id,
            title: a.name,
            cover: a.avatar,
            subtitle: a.albumCount != null
                ? l10n.streamingArtistAlbums(a.albumCount!)
                : '',
          ),
      ],
      loading: loading,
      artist: true,
      onTap: (item) =>
          context.push('/streaming/artist/${Uri.encodeComponent(item.id)}'),
    );
  }
}
