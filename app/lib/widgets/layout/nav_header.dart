// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async' show Timer, unawaited;
import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme_provider.dart';
import '../../services/netease/netease_api.dart';
import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../services/weather/weather_notifier.dart';
import '../../settings/settings_dialog.dart';
import '../../stores/app_prefs.dart';
import '../../stores/providers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../dialogs/kugou_login_button.dart';
import '../dialogs/netease_login_dialog.dart';
import '../dialogs/qqmusic_login_dialog.dart';
import '../dialogs/track_list_dialog.dart';
import '../player/s_controls.dart';
import '../common/anim.dart';
import '../common/toast.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

part 'nav_header/nav_header_accounts.dart';
part 'nav_header/nav_header_search_dropdown.dart';
part 'nav_header/nav_header_view.dart';
part 'nav_header/nav_header_weather.dart';

/// 顶部导航栏（对齐原项目 NavHeader.vue）。
///
/// 布局：返回 / 全局搜索框（SInput，回车跳搜索页）/（弹性留白）/ 用户 /
/// 齿轮下拉（主题循环 light→dark→system + 全局设置占位）。
/// 窗口控制（最小化/关闭）由 Linux 系统窗口管理，桌面壳不绘制
/// （原项目 WindowControls 仅在无边框窗口启用）。
class NavHeader extends ConsumerStatefulWidget {
  const NavHeader({super.key});

  @override
  ConsumerState<NavHeader> createState() => _NavHeaderState();
}

class _NavHeaderState extends ConsumerState<NavHeader>
    with TickerProviderStateMixin {
  // ── 搜索：输入 + 下拉 ──────────────────────────────────────
  late final TextEditingController _searchCtrl;
  final _searchFocus = FocusNode();

  /// 搜索下拉锚点：聚焦展开内联面板，点击外部收起（对齐原版 NavSearch
  /// 的搜索历史/热搜/建议交互，但做内联下拉而非弹出式弹窗）。
  final _searchLayerLink = LayerLink();
  OverlayEntry? _searchOverlayEntry;

  /// 输入文本 + 宽度动画合并监听（浮层面板内容实时刷新）。
  late final Listenable _searchListenable = Listenable.merge([
    _searchCtrl,
    _widthCtrl,
  ]);

  /// 面板开合动效 + 搜索框宽度动效（宽度与下拉面板同步跟随）。
  late final AnimationController _panelCtrl;
  late final AnimationController _widthCtrl;

  /// 搜索框宽度：折叠 280 → 聚焦/输入展开 420（有上限，防止缩放下
  /// 异常；下拉面板宽度实时跟随搜索框宽度）。
  static const double _searchCollapsedWidth = 280;
  static const double _searchExpandedWidth = 420;

  /// 面板开合动效时长（比宽度伸展略长，形成「先展开后伸展」的节奏）。
  static const Duration _panelExpandMs = Duration(milliseconds: 400);
  static const Duration _panelCollapseMs = Duration(milliseconds: 360);

  /// 搜索框宽度伸展动效时长（保持原节奏，不随面板加长）。
  static const Duration _widthExpandMs = Duration(milliseconds: 180);

  // ── 热搜 / 建议（NT + KG，对齐原版 getHotSearches / getSearchSuggest）──
  Timer? _suggestDebounce;
  String _suggestQuery = '';
  List<HotSearchItem> _hot = const [];
  bool _hotLoading = false;
  List<HotSearchItem> _kugouHot = const [];
  bool _kugouHotLoading = false;
  SuggestData _suggest = const SuggestData();
  bool _suggestLoading = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController();
    _searchFocus.addListener(_onSearchFocusChanged);
    _panelCtrl = AnimationController(
      vsync: this,
      duration: _panelExpandMs,
      reverseDuration: _panelCollapseMs,
    );
    _widthCtrl = AnimationController(vsync: this, duration: _widthExpandMs);
  }

  @override
  void dispose() {
    _searchFocus.removeListener(_onSearchFocusChanged);
    _suggestDebounce?.cancel();
    _hideSearchDropdown();
    _panelCtrl.dispose();
    _widthCtrl.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  double get _searchWidth =>
      _searchCollapsedWidth +
      (_searchExpandedWidth - _searchCollapsedWidth) * _widthCtrl.value;

  /// 搜索框聚焦 → 展开下拉；失焦 → 收起。
  void _onSearchFocusChanged() {
    if (_searchFocus.hasFocus) {
      _showSearchDropdown();
    } else {
      _hideSearchDropdown();
    }
  }

  void _showSearchDropdown() {
    if (_searchOverlayEntry != null) {
      _panelCtrl.forward();
      _widthCtrl.forward();
      return;
    }
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(builder: (_) => _buildSearchOverlay());
    _searchOverlayEntry = entry;
    overlay.insert(entry);
    _panelCtrl.forward(from: 0);
    _widthCtrl.forward();
    _loadHot();
  }

  void _hideSearchDropdown() {
    _suggestDebounce?.cancel();
    _widthCtrl.reverse();
    final entry = _searchOverlayEntry;
    if (entry == null) return;
    _searchOverlayEntry = null;
    // 收起动效结束后移除 overlay（期间快速重开时 forward 平滑接续）
    _panelCtrl.reverse().whenComplete(() {
      if (entry.mounted) entry.remove();
    });
  }

  /// 下拉浮层：透明拦截层（点击外部收起）+ 锚定面板。
  Widget _buildSearchOverlay() {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _searchFocus.unfocus(),
          ),
        ),
        CompositedTransformFollower(
          link: _searchLayerLink,
          // 面板顶边（followerAnchor topLeft）对齐搜索框底边
          // （targetAnchor bottomLeft）——Noctalia 式「嵌入」：面板紧贴
          // 搜索框下方、顶边圆角归零，视觉一体无间隙
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          offset: Offset.zero,
          child: ListenableBuilder(
            listenable: _searchListenable,
            builder: (_, _) => _SearchDropdown(
              width: _searchWidth,
              query: _searchCtrl.text.trim(),
              panelCtrl: _panelCtrl,
              hot: _hot,
              hotLoading: _hotLoading,
              kugouHot: _kugouHot,
              kugouHotLoading: _kugouHotLoading,
              suggest: _suggest,
              suggestLoading: _suggestLoading,
              onSearch: _submitSearch,
              onRemove: (word) =>
                  ref.read(appPrefsProvider.notifier).removeSearchHistory(word),
              onClear: () =>
                  ref.read(appPrefsProvider.notifier).clearSearchHistory(),
              onPickSong: _playSuggestSong,
              onPickAlbum: _openSuggestAlbum,
              onPickArtist: _openSuggestArtist,
              onPickPlaylist: _openSuggestPlaylist,
            ),
          ),
        ),
      ],
    );
  }

  /// 搜索框输入变化：空 → 热搜；非空 → 300ms debounce 拉建议。
  void _onSearchChanged(String text) {
    _suggestDebounce?.cancel();
    final query = text.trim();
    if (query.isEmpty) {
      setState(() {
        _suggest = const SuggestData();
        _suggestLoading = false;
      });
      _loadHot();
    } else {
      _suggestDebounce = Timer(
        const Duration(milliseconds: 300),
        () => _loadSuggest(query),
      );
    }
  }

  Future<void> _loadHot() async {
    // 双平台热搜并行：NT + KG，各自失败静默（对齐原版 console.warn）
    final futures = <Future<void>>[];
    if (_hot.isEmpty && !_hotLoading) {
      futures.add(_fetchNeteaseHot());
    }
    if (_kugouHot.isEmpty && !_kugouHotLoading) {
      futures.add(_fetchKugouHot());
    }
    await Future.wait(futures);
  }

  Future<void> _fetchNeteaseHot() async {
    if (_hotLoading) return;
    setState(() => _hotLoading = true);
    try {
      final items = await ref.read(neteaseApiProvider).searchHot();
      if (!mounted) return;
      setState(() {
        _hot = items;
        _hotLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _hotLoading = false);
    }
  }

  Future<void> _fetchKugouHot() async {
    if (_kugouHotLoading) return;
    setState(() => _kugouHotLoading = true);
    try {
      final items = await ref.read(kugouApiProvider).searchHot();
      if (!mounted) return;
      setState(() {
        _kugouHot = items;
        _kugouHotLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _kugouHotLoading = false);
    }
  }

  Future<void> _loadSuggest(String query) async {
    final word = query.trim();
    if (word.isEmpty) return;
    setState(() {
      _suggestQuery = word;
      _suggestLoading = true;
    });
    // 双平台建议并行；单平台失败不影响另一平台
    final results = await Future.wait<SuggestData>([
      _safeSuggest(() => ref.read(neteaseApiProvider).searchSuggest(word)),
      _safeSuggest(() => ref.read(kugouApiProvider).searchSuggest(word)),
    ]);
    if (!mounted || _suggestQuery != word) return; // 过期响应丢弃
    final ne = results[0];
    final kg = results[1];
    setState(() {
      // KG建议条目 source=='kugou'，合并进同一分类列表（行内带平台角标）
      _suggest = SuggestData(
        songs: [...ne.songs, ...kg.songs],
        albums: [...ne.albums, ...kg.albums],
        artists: ne.artists,
        playlists: ne.playlists,
      );
      _suggestLoading = false;
    });
  }

  /// 包装建议请求：失败返回空 [SuggestData]（单平台失败不阻塞合并）。
  Future<SuggestData> _safeSuggest(Future<SuggestData> Function() fetch) async {
    try {
      return await fetch();
    } catch (_) {
      return const SuggestData();
    }
  }

  void _submitSearch(String q) {
    final query = q.trim();
    if (query.isEmpty) return;
    // 对齐原版 data store：提交即记录搜索历史
    ref.read(appPrefsProvider.notifier).addSearchHistory(query);
    context.go('/search?q=${Uri.encodeQueryComponent(query)}');
    _searchFocus.unfocus();
  }

  // ── 建议点击（对齐原版 navigateToResource）──────────────

  /// 建议歌曲：解析播放 URL → 完整转码播放。
  ///
  /// 建议条目本身只有标题/歌手（无封面），播放前先补齐完整 Track：
  /// - NT：song_detail 批量取详情（含封面/歌手/专辑），失败回退轻量构造；
  /// - KG：建议只有 songid，按歌名搜索取 hash + 封面（[suggestSongToTrack]）。
  Future<void> _playSuggestSong(SuggestSongItem song) async {
    final String? url;
    final Track track;
    if (song.source == 'kugou') {
      final kugouApi = ref.read(kugouApiProvider);
      final resolved = await kugouApi.suggestSongToTrack(
        song.name,
        singer: song.artist,
      );
      if (resolved == null || resolved.kugou == null) {
        if (mounted) toast(context.l10n.trackListNoPlayableSource);
        return;
      }
      track = resolved;
      url = await kugouApi.resolvePlayUrl(resolved.kugou!);
    } else {
      // NT：先取详情补封面（建议条目无封面字段），失败回退轻量构造
      Track? detail;
      try {
        final list = await ref.read(neteaseApiProvider).songsDetailByIds([
          song.id,
        ]);
        if (list.isNotEmpty) detail = list.first;
      } catch (_) {
        // 详情失败不影响播放，回退轻量 Track
      }
      if (detail != null) {
        track = detail;
      } else {
        final artists = song.artist == null
            ? const <TrackArtist>[]
            : song.artist!
                  .split(' / ')
                  .map((n) => TrackArtist(name: n))
                  .toList();
        track = Track(
          id: song.id,
          title: song.name,
          artists: artists,
          album: song.album == null ? null : TrackAlbum(name: song.album!),
        );
      }
      url = await ref.read(neteaseApiProvider).resolvePlayUrl(song.id);
    }
    if (!mounted) return;
    if (url == null) {
      toast(context.l10n.trackListNoPlayableSource);
      return;
    }
    unawaited(
      ref.read(playbackProvider.notifier).playNow(track, resolvedUrl: url),
    );
    _searchFocus.unfocus();
  }

  /// 建议专辑：按来源分发专辑详情弹窗（NT / KG各自专辑接口，
  /// albumid 不能跨平台混用，对齐搜索页 `_onCoverTap` 的平台分发）。
  void _openSuggestAlbum(SuggestSimpleItem album) {
    _searchFocus.unfocus();
    final cover = CoverItem(id: album.id, title: album.name);
    if (album.source == 'kugou') {
      showKugouAlbumDialog(context, cover);
    } else {
      showNeteaseAlbumDialog(context, cover);
    }
  }

  /// 建议歌手：NT歌手热门歌曲弹窗。
  void _openSuggestArtist(SuggestSimpleItem artist) {
    _searchFocus.unfocus();
    showNeteaseArtistDialog(
      context,
      CoverItem(id: artist.id, title: artist.name),
    );
  }

  /// 建议歌单：NT歌单详情弹窗。
  void _openSuggestPlaylist(SuggestSimpleItem playlist) {
    _searchFocus.unfocus();
    showPlaylistDetailDialog(
      context,
      CoverItem(id: playlist.id, title: playlist.name),
    );
  }

  /// 返回：优先 pop 栈内页面（全屏播放器 / 流媒体详情），否则直接回主页。
  /// 注意：go_router 的分支切换（顶栏搜索 context.go('/search')）不产生
  /// 可 pop 的历史，这里统一回落主页，不做复杂的来处跟踪。
  void _handleBack(BuildContext context) {
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            // 返回（pop 栈内页面优先，否则回主页；恒可点，不随
            // go_router 分支历史禁用）
            IconButton(
              tooltip: l10n.commonBack,
              onPressed: () => _handleBack(context),
              icon: const Icon(EtaIcons.leftSmall, size: 22),
            ),
            const SizedBox(width: 8),
            _NavHeaderSearchField(
              layerLink: _searchLayerLink,
              widthAnimation: _widthCtrl,
              collapsedWidth: _searchCollapsedWidth,
              expandedWidth: _searchExpandedWidth,
              searchFocus: _searchFocus,
              searchCtrl: _searchCtrl,
              hintText: l10n.navHeaderSearchHint,
              onChanged: _onSearchChanged,
              onSubmitted: _submitSearch,
            ),
            const Spacer(),
            // 微型天气（头像左侧；默认关闭，见设置 → 外观 → 天气）
            const _WeatherMini(),
            // 与账号菜单保持间距（避免组件过小且贴太近）
            const SizedBox(width: 12),
            // 账号（多平台：NT / KG / QM占位）
            const _AccountsMenu(),
            const SizedBox(width: 4),
            const _NavHeaderActionsMenu(),
          ],
        ),
      ),
    );
  }
}
