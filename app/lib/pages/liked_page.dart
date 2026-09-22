// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/netease/track.dart';
import '../services/playback/playback_notifier.dart';
import '../stores/app_prefs.dart';
import '../stores/providers.dart';
import '../stores/shell_page_state.dart';
import '../../l10n/l10n.dart';
import '../l10n/generated/app_localizations.dart';
import '../widgets/dialogs/collection_platform.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/streaming/empty_state.dart';
import '../widgets/list/song_list.dart';
import '../widgets/common/toast.dart';
import '../widgets/dialogs/track_context_menu.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'liked/liked_page_actions.dart';
part 'liked/liked_page_view.dart';

/// 我喜欢页（对齐原项目 Liked.vue）。
///
/// 平台切换与数据（NT / KG / QM / NK）**全部由 `CollectionPlatform` 注册表
/// 驱动**：平台列表、登录引导、登录动作、红心键、列表数据、刷新/同步语义、
/// 空态文案都来自适配器；本页不含任何具体平台分支。新增音源只需注册适配器。
class LikedPage extends ConsumerStatefulWidget {
  const LikedPage({super.key});

  @override
  ConsumerState<LikedPage> createState() => _LikedPageState();
}

class _LikedPageState extends ConsumerState<LikedPage> {
  /// 当前平台 source；存于 [likedPlatformProvider]（跨壳内容卸载/重挂载保留）。
  late String _platform;
  bool _resolving = false;

  /// 当前平台「我喜欢」是否可用（QQ 本机红心无需登录）。
  bool get _available => collectionPlatform(_platform).likedAvailable(ref);

  @override
  void initState() {
    super.initState();
    // 优先恢复上次显式选择（壳内容因播放页展开被卸载后重建）；实验性音源
    // 已关闭时不保留 NK 选择。无显式选择时按登录态给默认值。
    final restored = ref.read(likedPlatformProvider);
    _platform = (restored == 'neko' && !ref.read(appPrefsProvider).nekoEnabled)
        ? defaultLikedPlatform(ref)
        : (restored ?? defaultLikedPlatform(ref));
    if (_available) collectionPlatform(_platform).ensureLikedLoaded(ref);
  }

  @override
  Widget build(BuildContext context) => _buildPage(context);
}
