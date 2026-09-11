// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/netease/netease_api.dart';
import '../services/playback/playback_notifier.dart';
import '../stores/app_prefs.dart';
import '../stores/providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../widgets/list/cover_grid.dart';
import '../widgets/dialogs/netease_login_dialog.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/common/toast.dart';
import '../widgets/dialogs/track_list_dialog.dart';
import '../widgets/home/action_card.dart';
import '../widgets/home/daily_hero.dart';
import '../widgets/home/section_title.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'home/home_page_actions.dart';
part 'home/home_page_view.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomeData {
  const _HomeData({
    this.playlists = const [],
    this.albums = const [],
    this.artists = const [],
  });

  final List<CoverItem> playlists;
  final List<CoverItem> albums;
  final List<CoverItem> artists;

  bool get loaded =>
      playlists.isNotEmpty || albums.isNotEmpty || artists.isNotEmpty;
}

class _HomePageState extends ConsumerState<HomePage> {
  _HomeData _data = const _HomeData();
  bool _loading = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _fetchAll();
  }

  @override
  Widget build(BuildContext context) => _buildPage(context);
}
