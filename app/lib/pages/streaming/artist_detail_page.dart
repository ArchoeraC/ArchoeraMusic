// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/netease/netease_api.dart';
import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../services/streaming/streaming_client.dart';
import '../../services/streaming/streaming_models.dart';
import '../../services/streaming/streaming_provider.dart';
import '../../l10n/l10n.dart';
import '../../widgets/dialogs/track_context_menu.dart';
import '../../widgets/list/cover_grid.dart';
import '../../widgets/list/song_list.dart';
import 'detail_scaffold.dart';

part 'artist_detail/artist_detail_page_actions.dart';
part 'artist_detail/artist_detail_page_view.dart';

/// 流媒体歌手详情页：专辑网格 + 全部歌曲。
class StreamingArtistDetailPage extends ConsumerStatefulWidget {
  const StreamingArtistDetailPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<StreamingArtistDetailPage> createState() =>
      _StreamingArtistDetailPageState();
}

class _StreamingArtistDetailPageState
    extends ConsumerState<StreamingArtistDetailPage> {
  List<StreamingAlbum>? _albums;
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

  void _setLoadedData(List<StreamingAlbum> albums, List<Track> songs) {
    setState(() {
      _albums = albums;
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
  Widget build(BuildContext context) => _buildArtistDetailPage(context);
}
