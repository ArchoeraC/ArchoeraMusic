import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../services/streaming/streaming_provider.dart';
import '../dialogs/track_context_menu.dart';
import '../list/song_list.dart';
import '../player/s_controls.dart';

/// 歌曲 Tab：播放全部 + 本地过滤搜索 + 歌曲列表。
class StreamingSongsTab extends ConsumerStatefulWidget {
  const StreamingSongsTab({super.key});

  @override
  ConsumerState<StreamingSongsTab> createState() => _SongsTabState();
}

class _SongsTabState extends ConsumerState<StreamingSongsTab> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<Track> _filtered(List<Track> songs) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return songs;
    return songs
        .where((t) =>
            t.title.toLowerCase().contains(q) ||
            t.artistNames.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(streamingProvider);
    final playback = ref.watch(playbackProvider);
    final songs = state.songs;
    final filtered = _filtered(songs);
    final notifier = ref.read(playbackProvider.notifier);

    void playList(List<Track> list, Track start) {
      final idx = list.indexWhere((t) => t.id == start.id);
      notifier.playQueue(list, startIndex: idx < 0 ? 0 : idx);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 操作栏：播放全部 + 搜索
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
          child: Row(
            children: [
              SButton(
                label: l10n.commonPlayAll,
                icon: Icons.play_arrow,
                variant: SButtonVariant.primary,
                size: SButtonSize.small,
                onPressed: songs.isEmpty
                    ? null
                    : () => notifier.playQueue(songs),
              ),
              const Spacer(),
              SizedBox(
                width: 200,
                child: SInput(
                  controller: _searchCtrl,
                  hintText: l10n.commonSearch,
                  prefixIcon: Icons.search,
                  clearable: true,
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            ],
          ),
        ),
        if (songs.isEmpty && !state.loading)
          Expanded(
            child: Center(
              child: Text(
                l10n.streamingEmptyNoResults,
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              ),
            ),
          )
        else
          Expanded(
            child: SongList(
              items: filtered,
              playingId: playback.trackId,
              isPlaying: playback.playing,
              showSource: false,
              onPlay: (t) => playList(filtered, t),
              onContextMenu: (t, pos) => showTrackContextMenu(
                context,
                ref: ref,
                track: t,
                position: pos,
                onPlay: () => playList(filtered, t),
              ),
            ),
          ),
      ],
    );
  }
}
