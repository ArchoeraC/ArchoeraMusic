import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../services/streaming/streaming_provider.dart';

/// 顶栏数量统计（跟随当前 Tab）。
class StreamingCountLabel extends StatelessWidget {
  const StreamingCountLabel({
    super.key,
    required this.index,
    required this.state,
    required this.l10n,
  });

  final int index;
  final StreamingState state;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final String text;
    switch (index) {
      case 0:
        text = l10n.streamingTotalSongs(state.songs.length);
      case 1:
        text = l10n.streamingTotalAlbums(state.albums.length);
      case 2:
        text = l10n.streamingTotalArtists(state.artists.length);
      default:
        text = l10n.streamingTotalPlaylists(state.playlists.length);
    }
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12.5,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
      ),
    );
  }
}
