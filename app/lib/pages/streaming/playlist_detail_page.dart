// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../services/streaming/streaming_client.dart';
import '../../services/streaming/streaming_provider.dart';
import '../../l10n/l10n.dart';
import '../../widgets/dialogs/track_context_menu.dart';
import '../../widgets/list/song_list.dart';
import 'detail_scaffold.dart';

part 'playlist_detail/playlist_detail_page_actions.dart';
part 'playlist_detail/playlist_detail_page_view.dart';

/// 流媒体歌单详情页。
class StreamingPlaylistDetailPage extends ConsumerStatefulWidget {
  const StreamingPlaylistDetailPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<StreamingPlaylistDetailPage> createState() =>
      _StreamingPlaylistDetailPageState();
}

class _StreamingPlaylistDetailPageState
    extends ConsumerState<StreamingPlaylistDetailPage> {
  List<Track>? _songs;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _startLoading() {
    setState(() {
      _loading = true;
      _error = null;
    });
  }

  void _setSongsLoaded(List<Track> songs) {
    setState(() {
      _songs = songs;
      _loading = false;
    });
  }

  void _setLoadError(String error) {
    setState(() {
      _error = error;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) => _buildPlaylistDetailPage(context);
}
