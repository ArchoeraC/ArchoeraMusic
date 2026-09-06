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

part 'album_detail/album_detail_page_actions.dart';
part 'album_detail/album_detail_page_view.dart';

/// 流媒体专辑详情页。
class StreamingAlbumDetailPage extends ConsumerStatefulWidget {
  const StreamingAlbumDetailPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<StreamingAlbumDetailPage> createState() =>
      _StreamingAlbumDetailPageState();
}

class _StreamingAlbumDetailPageState
    extends ConsumerState<StreamingAlbumDetailPage> {
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
  Widget build(BuildContext context) => _buildAlbumDetailPage(context);
}
