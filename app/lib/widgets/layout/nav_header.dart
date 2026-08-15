import 'dart:async' show Timer, unawaited;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
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
import '../dialogs/track_list_dialog.dart';
import '../player/s_controls.dart';
import '../common/anim.dart';
import '../common/toast.dart';

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
  late final Listenable _searchListenable =
      Listenable.merge([_searchCtrl, _widthCtrl]);

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

  // ── 热搜 / 建议（网易云 + 酷狗，对齐原版 getHotSearches / getSearchSuggest）──
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
              onRemove: (word) => ref
                  .read(appPrefsProvider.notifier)
                  .removeSearchHistory(word),
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
    // 双平台热搜并行：网易云 + 酷狗，各自失败静默（对齐原版 console.warn）
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
      _safeSuggest(
        () => ref.read(neteaseApiProvider).searchSuggest(word),
      ),
      _safeSuggest(() => ref.read(kugouApiProvider).searchSuggest(word)),
    ]);
    if (!mounted || _suggestQuery != word) return; // 过期响应丢弃
    final ne = results[0];
    final kg = results[1];
    setState(() {
      // 酷狗建议条目 source=='kugou'，合并进同一分类列表（行内带平台角标）
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
  /// - 网易云：song_detail 批量取详情（含封面/歌手/专辑），失败回退轻量构造；
  /// - 酷狗：建议只有 songid，按歌名搜索取 hash + 封面（[suggestSongToTrack]）。
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
      // 网易云：先取详情补封面（建议条目无封面字段），失败回退轻量构造
      Track? detail;
      try {
        final list = await ref
            .read(neteaseApiProvider)
            .songsDetailByIds([song.id]);
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

  /// 建议专辑：按来源分发专辑详情弹窗（网易云 / 酷狗各自专辑接口，
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

  /// 建议歌手：网易云歌手热门歌曲弹窗。
  void _openSuggestArtist(SuggestSimpleItem artist) {
    _searchFocus.unfocus();
    showNeteaseArtistDialog(
      context,
      CoverItem(id: artist.id, title: artist.name),
    );
  }

  /// 建议歌单：网易云歌单详情弹窗。
  void _openSuggestPlaylist(SuggestSimpleItem playlist) {
    _searchFocus.unfocus();
    showPlaylistDetailDialog(
      context,
      CoverItem(id: playlist.id, title: playlist.name),
    );
  }

  /// 主题循环按钮图标（展示当前模式）。
  IconData get _themeIcon => switch (ref.watch(themeModeProvider)) {
    ThemeMode.light => Icons.light_mode_outlined,
    ThemeMode.dark => Icons.dark_mode_outlined,
    ThemeMode.system => Icons.brightness_auto_outlined,
  };

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
              icon: const Icon(Icons.chevron_left, size: 22),
            ),
            const SizedBox(width: 8),
            // 全局搜索框（对齐 NavSearch.vue，回车跳转搜索页；聚焦展开
            // 内联搜索历史/热搜/建议下拉，Esc/点击外部收起；聚焦时宽度
            // 伸展到上限 420，下拉面板宽度同步跟随）
            Focus(
              canRequestFocus: false,
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.escape) {
                  _searchFocus.unfocus();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: CompositedTransformTarget(
                link: _searchLayerLink,
                child: AnimatedBuilder(
                  animation: _widthCtrl,
                  builder: (_, child) => SizedBox(
                    width: _searchWidth,
                    child: child,
                  ),
                  child: SInput(
                    controller: _searchCtrl,
                    focusNode: _searchFocus,
                    hintText: l10n.navHeaderSearchHint,
                    prefixIcon: Icons.search,
                    clearable: true,
                    textInputAction: TextInputAction.search,
                    onChanged: _onSearchChanged,
                    onSubmitted: _submitSearch,
                  ),
                ),
              ),
            ),
            const Spacer(),
            // 微型天气（头像左侧；默认关闭，见设置 → 外观 → 天气）
            const _WeatherMini(),
            // 与账号菜单保持间距（避免组件过小且贴太近）
            const SizedBox(width: 12),
            // 账号（多平台：网易云 / 酷狗 / QQ 音乐占位）
            const _AccountsMenu(),
            const SizedBox(width: 4),
            // 齿轮下拉（对齐 NavHeader SDropdownMenu：主题 + 全局设置）
            PopupMenuButton<String>(
              tooltip: l10n.commonMore,
              position: PopupMenuPosition.under,
              offset: const Offset(0, 6),
              // 性能模式：菜单直出，无淡入/弹出动效
              popUpAnimationStyle: noAnim(context)
                  ? AnimationStyle.noAnimation
                  : null,
              onSelected: (key) {
                if (key == 'theme') {
                  ref.read(themeModeProvider.notifier).cycle();
                } else if (key == 'settings') {
                  showSettingsDialog(context);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'theme',
                  height: 40,
                  child: Row(
                    children: [
                      Icon(_themeIcon, size: 17),
                      const SizedBox(width: 10),
                      Text(switch (ref.watch(themeModeProvider)) {
                        ThemeMode.light => l10n.navHeaderThemeLight,
                        ThemeMode.dark => l10n.navHeaderThemeDark,
                        ThemeMode.system => l10n.navHeaderThemeSystem,
                      }),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'settings',
                  height: 40,
                  child: Row(
                    children: [
                      const Icon(Icons.settings_outlined, size: 17),
                      const SizedBox(width: 10),
                      Text(l10n.commonSettings),
                    ],
                  ),
                ),
              ],
              child: const SizedBox(
                width: 40,
                height: 40,
                child: Center(child: Icon(Icons.more_vert, size: 20)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 搜索下拉面板（内联，非弹窗；对齐原版 NavSearch 的搜索历史/热搜/建议）。
///
/// 视觉：与播放条队列面板同款毛玻璃（blur24 + 半透明表面 + 细描边 +
/// 投影）；嵌入式定位——顶边紧贴搜索框底边、顶部圆角归零（Noctalia 式
/// curvy 融合），仅保留底部圆角。动效：从顶部向下展开（SizeTransition
/// topCenter，与播放条队列 popup 的 bottomCenter 方向相反）+ 淡入；
/// 宽度由搜索框实时跟随（输入时伸展有上限）。
///
/// 内容：空输入 → 搜索历史 chips + 网易云热搜 Top20；有输入 →
/// 快捷搜索行 + 分类建议（歌曲 / 专辑 / 歌手 / 歌单）。
class _SearchDropdown extends ConsumerWidget {
  const _SearchDropdown({
    required this.width,
    required this.query,
    required this.panelCtrl,
    required this.hot,
    required this.hotLoading,
    required this.kugouHot,
    required this.kugouHotLoading,
    required this.suggest,
    required this.suggestLoading,
    required this.onSearch,
    required this.onRemove,
    required this.onClear,
    required this.onPickSong,
    required this.onPickAlbum,
    required this.onPickArtist,
    required this.onPickPlaylist,
  });

  /// 面板宽度（跟随搜索框宽度动画）。
  final double width;

  /// 当前输入（trim）。
  final String query;

  /// 面板开合动画。
  final Animation<double> panelCtrl;

  final List<HotSearchItem> hot;
  final bool hotLoading;
  final List<HotSearchItem> kugouHot;
  final bool kugouHotLoading;
  final SuggestData suggest;
  final bool suggestLoading;

  final ValueChanged<String> onSearch;
  final ValueChanged<String> onRemove;
  final VoidCallback onClear;
  final ValueChanged<SuggestSongItem> onPickSong;
  final ValueChanged<SuggestSimpleItem> onPickAlbum;
  final ValueChanged<SuggestSimpleItem> onPickArtist;
  final ValueChanged<SuggestSimpleItem> onPickPlaylist;

  /// 底部圆角（顶边归零贴搜索框）。
  static const double _radius = 16;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final history = ref.watch(appPrefsProvider).searchHistory;

    final body = query.isNotEmpty
        ? _buildSuggestBody(context, scheme)
        : _buildExploreBody(context, scheme, history);

    // 展开动效：从顶部向下生长（与播放条队列 popup bottomCenter 反向）；
    // 曲线 linearToEaseOut（前段匀速线性 + 结尾微缓出）与宽度伸展的
    // 线性节奏协调，避免 easeOutCubic 前段过快缺少线性流动感
    final expand = CurvedAnimation(
      parent: panelCtrl,
      curve: Curves.linearToEaseOut,
      reverseCurve: Curves.easeInCubic,
    );
    final fade = CurveTween(curve: const Interval(0.0, 0.45)).animate(panelCtrl);

    // 毛玻璃面板（对齐 QueuePanel._glass：blur24 + 半透明表面 + 描边 +
    // 投影），顶边圆角归零与搜索框融为一体
    final panel = ClipRRect(
      borderRadius: const BorderRadius.vertical(
        bottom: Radius.circular(_radius),
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.66),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 28,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: SizedBox(
              width: width,
              // 内容超高（热搜+历史 / 建议多分类）时内部滚动；
              // 上限扣除顶栏高度与窗口边距，防止溢出屏幕
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: (MediaQuery.sizeOf(context).height - 120)
                      .clamp(200.0, 460.0),
                ),
                child: ScrollConfiguration(
                  // 隐藏滚动条：桌面端默认 MaterialScrollbar 悬停会出现，
                  // 与毛玻璃面板视觉冲突
                  behavior: ScrollConfiguration.of(context)
                      .copyWith(scrollbars: false),
                  child: SingleChildScrollView(child: body),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return SizedBox(
      // 强制外层容器宽度 = 面板宽度（= 搜索框宽度，跟随动画）：
      // Overlay theater 给 follower 的约束是 loose(0→窗口宽)，此时
      // SizeTransition 内部 Align 因 maxWidth 有限不 shrink-wrap 而撑满
      // 窗口宽，把面板水平居中 → 与搜索框错位（偏移 (窗口宽-面板宽)/2）。
      // 包一层 SizedBox 强制宽度后容器与面板等宽，topCenter 对齐无偏差。
      width: width,
      child: ClipRect(
        child: FadeTransition(
          opacity: fade,
          child: SizeTransition(
            sizeFactor: expand,
            axis: Axis.vertical,
            alignment: Alignment.topCenter,
            child: panel,
          ),
        ),
      ),
    );
  }

  // ── 空输入：搜索历史 + 热搜 ─────────────────────────────

  Widget _buildExploreBody(
    BuildContext context,
    ColorScheme scheme,
    List<String> history,
  ) {
    final l10n = context.l10n;
    final children = <Widget>[];

    if (history.isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 2),
          child: Row(
            children: [
              Icon(Icons.history, size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                l10n.searchHistory,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: onClear,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    l10n.searchHistoryClear,
                    style: TextStyle(fontSize: 11.5, color: scheme.primary),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final word in history)
                _HistoryChip(word: word, onSearch: onSearch, onRemove: onRemove),
            ],
          ),
        ),
      );
    }

    // 热搜（Top20；加载中显示占位，失败静默）
    if (hotLoading) {
      children.add(_sectionTitle(context, Icons.local_fire_department_outlined,
          l10n.searchHot, bottom: 10));
      children.add(
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    } else if (hot.isNotEmpty) {
      children.add(_sectionTitle(context, Icons.local_fire_department_outlined,
          l10n.searchHot, bottom: 2));
      for (var i = 0; i < hot.length && i < 20; i++) {
        children.add(_hotTile(scheme, hot[i], i));
      }
      children.add(const SizedBox(height: 6));
    }

    // 酷狗热搜（独立区段；标题带平台名区分，加载中占位，失败静默）
    final kugouHotTitle = '${l10n.brandKugou} · ${l10n.searchHot}';
    if (kugouHotLoading) {
      children.add(_sectionTitle(
          context, Icons.local_fire_department_outlined, kugouHotTitle,
          bottom: 10));
      children.add(
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    } else if (kugouHot.isNotEmpty) {
      children.add(_sectionTitle(
          context, Icons.local_fire_department_outlined, kugouHotTitle,
          bottom: 2));
      for (var i = 0; i < kugouHot.length && i < 20; i++) {
        children.add(_hotTile(scheme, kugouHot[i], i));
      }
      children.add(const SizedBox(height: 6));
    }

    if (children.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.history, size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                l10n.searchHistoryEmpty,
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  /// 热搜单行：序号（前三主色）+ 关键词 + 热度。
  Widget _hotTile(ColorScheme scheme, HotSearchItem item, int index) {
    return InkWell(
      onTap: () => onSearch(item.keyword),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: index < 3
                      ? scheme.primary
                      : scheme.onSurfaceVariant.withValues(alpha: 0.55),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.keyword,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            if (item.score != null)
              Text(
                '${item.score}',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── 有输入：快捷搜索 + 分类建议 ─────────────────────────

  Widget _buildSuggestBody(BuildContext context, ColorScheme scheme) {
    final l10n = context.l10n;
    final children = <Widget>[
      // 快捷搜索行（提交并记录历史）
      InkWell(
        onTap: () => onSearch(query),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.search, size: 16, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.searchQuick(query),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              Icon(Icons.north_west, size: 14, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    ];

    if (suggestLoading) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(
                l10n.pageSearching,
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      if (suggest.songs.isNotEmpty) {
        children.add(_sectionTitle(context, Icons.music_note_outlined,
            l10n.commonSongs));
        for (final song in suggest.songs) {
          children.add(_suggestSongRow(scheme, song));
        }
      }
      if (suggest.artists.isNotEmpty) {
        children.add(_sectionTitle(
            context, Icons.person_outline, l10n.commonArtists));
        for (final artist in suggest.artists) {
          children.add(_suggestSimpleRow(scheme, artist, Icons.person_outline));
        }
      }
      if (suggest.albums.isNotEmpty) {
        children.add(
            _sectionTitle(context, Icons.album_outlined, l10n.commonAlbums));
        for (final album in suggest.albums) {
          children.add(_suggestSimpleRow(scheme, album, Icons.album_outlined));
        }
      }
      if (suggest.playlists.isNotEmpty) {
        children.add(_sectionTitle(
            context, Icons.queue_music_outlined, l10n.commonPlaylists));
        for (final playlist in suggest.playlists) {
          children.add(
              _suggestSimpleRow(scheme, playlist, Icons.queue_music_outlined));
        }
      }
      if (suggest.isEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Text(
              l10n.pageSearchEmpty,
              style: TextStyle(
                fontSize: 12.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      }
      children.add(const SizedBox(height: 6));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  /// 分类标题行（图标 + 文案）。
  Widget _sectionTitle(
    BuildContext context,
    IconData icon,
    String title, {
    double bottom = 2,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 8, 12, bottom),
      child: Row(
        children: [
          Icon(icon, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 建议歌曲行：标题 + 歌手 · 专辑副标题（酷狗条目行内带平台角标）。
  Widget _suggestSongRow(ColorScheme scheme, SuggestSongItem song) {
    final subtitle = [
      if (song.artist != null && song.artist!.isNotEmpty) song.artist!,
      if (song.album != null && song.album!.isNotEmpty) song.album!,
    ].join(' · ');
    return InkWell(
      onTap: () => onPickSong(song),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(
              Icons.music_note,
              size: 14,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (song.source == 'kugou') ...[
                        const _SourceDot(),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          song.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 建议简单行（歌手 / 专辑 / 歌单）。
  Widget _suggestSimpleRow(
    ColorScheme scheme,
    SuggestSimpleItem item,
    IconData icon,
  ) {
    return InkWell(
      onTap: () {
        switch (icon) {
          case Icons.person_outline:
            onPickArtist(item);
          case Icons.album_outlined:
            onPickAlbum(item);
          default:
            onPickPlaylist(item);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(
              icon,
              size: 14,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Row(
                children: [
                  if (item.source == 'kugou') ...[
                    const _SourceDot(),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            if (item.subtitle != null && item.subtitle!.isNotEmpty)
              Text(
                item.subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 建议行平台角标（酷狗：蓝底白字「酷」，对齐搜索页 SongRow 的
/// _SourceBadge 样式；仅酷狗条目渲染，网易云不显示）。
class _SourceDot extends StatelessWidget {
  const _SourceDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 16,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF00A7E0),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        '酷',
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// 搜索历史 chip：主体点击直达搜索，尾部小叉删除单条。
class _HistoryChip extends StatelessWidget {
  const _HistoryChip({
    required this.word,
    required this.onSearch,
    required this.onRemove,
  });

  final String word;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => onSearch(word),
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.only(left: 10, top: 5, bottom: 5),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  word,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ),
          ),
          InkWell(
            onTap: () => onRemove(word),
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              child: Icon(Icons.close, size: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// 账号入口（多平台）：未登录显示登录入口，已登录显示主账号（优先网易云
/// 头像）。菜单列出各平台登录态：网易云 / 酷狗（均支持扫码登录），
/// QQ 音乐暂不可用（原版 SPlayer-Next 无登录；Mineradio 走祈水第三方
/// 授权平台，Flutter 桌面不移植）。
class _AccountsMenu extends ConsumerWidget {
  const _AccountsMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final netease = ref.watch(neteaseAuthProvider);
    final kugouApi = ref.read(kugouApiProvider);

    return ListenableBuilder(
      listenable: kugouApi,
      builder: (context, _) {
        final kugou = kugouApi.session;

        // 主账号：网易云 > 酷狗
        final primaryNetease = netease != null;
        final primaryKugou = !primaryNetease && kugou != null;
        final anyLoggedIn = primaryNetease || primaryKugou;

        final avatarUrl = netease?.avatarUrl?.trim();
        final neteaseNick = netease?.nickname.trim() ?? '';
        final kugouNick = kugou?.nickname?.trim() ?? '';

        Widget primary;
        if (primaryNetease) {
          primary = _AccountAvatar(avatarUrl: avatarUrl, nickname: neteaseNick);
        } else if (primaryKugou) {
          primary = _AccountAvatar(
            avatarUrl: kugou.avatarUrl,
            nickname: kugouNick.isEmpty ? kugou.userid : kugouNick,
          );
        } else {
          primary = Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.person_outline,
              size: 19,
              color: colorScheme.primary,
            ),
          );
        }

        return PopupMenuButton<String>(
          tooltip: anyLoggedIn
              ? l10n.navHeaderAccount
              : l10n.navHeaderLoginAccount,
          position: PopupMenuPosition.under,
          offset: const Offset(0, 6),
          // 性能模式：菜单直出，无淡入/弹出动效
          popUpAnimationStyle: noAnim(context)
              ? AnimationStyle.noAnimation
              : null,
          onSelected: (key) async {
            switch (key) {
              case 'login_netease':
                showNeteaseLoginDialog(context);
              case 'logout_netease':
                await ref.read(neteaseAuthProvider.notifier).logout();
              case 'login_kugou':
                showDialog<bool>(
                  context: context,
                  barrierColor: Colors.black.withValues(alpha: 0.5),
                  barrierDismissible: false,
                  builder: (_) => const KgQrLoginDialog(),
                );
              case 'logout_kugou':
                ref.read(kugouApiProvider).clearSession();
            }
          },
          itemBuilder: (_) => [
            // ── 网易云 / 酷狗（同构：标题 + 登录入口 或 头像+昵称+退出）──
            ..._platformSection(
              l10n: l10n,
              title: l10n.navHeaderNeteaseMusic,
              loggedIn: netease != null,
              loginValue: 'login_netease',
              logoutValue: 'logout_netease',
              nameValue: 'name_netease',
              avatarUrl: avatarUrl,
              avatarName: neteaseNick,
              displayName: neteaseNick.isEmpty
                  ? l10n.navHeaderNeteaseAccount
                  : neteaseNick,
            ),
            ..._platformSection(
              l10n: l10n,
              title: l10n.navHeaderKugouMusic,
              loggedIn: kugou != null,
              loginValue: 'login_kugou',
              logoutValue: 'logout_kugou',
              nameValue: 'name_kugou',
              avatarUrl: kugou?.avatarUrl,
              avatarName: kugouNick.isEmpty ? (kugou?.userid ?? '') : kugouNick,
              displayName: kugouNick.isEmpty
                  ? l10n.navHeaderKugouId(kugou?.userid ?? '')
                  : kugouNick,
            ),
            // ── QQ 音乐（占位） ────────────────────────────────
            _MenuSectionLabel(l10n.navHeaderQqMusic),
            PopupMenuItem(
              value: 'qq_soon',
              enabled: false,
              height: 36,
              child: Row(
                children: [
                  const Icon(Icons.hourglass_empty, size: 17),
                  const SizedBox(width: 10),
                  Text(l10n.navHeaderComingSoon),
                ],
              ),
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                primary,
                if (anyLoggedIn) ...[
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 100),
                    child: Text(
                      primaryNetease
                          ? neteaseNick
                          : (kugouNick.isEmpty ? l10n.brandKugou : kugouNick),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.arrow_drop_down,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// 单个平台账号区段：标题 + 未登录「扫码登录」入口，或已登录的
  /// 「头像 + 昵称」与退出项（网易云 / 酷狗同构复用）。
  List<PopupMenuEntry<String>> _platformSection({
    required AppLocalizations l10n,
    required String title,
    required bool loggedIn,
    required String loginValue,
    required String logoutValue,
    required String nameValue,
    String? avatarUrl,
    required String avatarName,
    required String displayName,
  }) {
    return [
      _MenuSectionLabel(title),
      if (!loggedIn)
        PopupMenuItem(
          value: loginValue,
          height: 36,
          child: Row(
            children: [
              const Icon(Icons.qr_code_2, size: 17),
              const SizedBox(width: 10),
              Text(l10n.navHeaderQrLogin),
            ],
          ),
        )
      else ...[
        PopupMenuItem(
          value: nameValue,
          enabled: false,
          height: 44,
          child: Row(
            children: [
              SizedBox(
                width: 30,
                height: 30,
                child: _AccountAvatar(
                  avatarUrl: avatarUrl,
                  nickname: avatarName,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: logoutValue,
          height: 36,
          child: Row(
            children: [
              const Icon(Icons.logout, size: 17),
              const SizedBox(width: 10),
              Text(l10n.navHeaderLogout),
            ],
          ),
        ),
      ],
      const PopupMenuDivider(height: 4),
    ];
  }
}

/// 菜单区段标题（不可选中，仅展示平台名）。
class _MenuSectionLabel extends PopupMenuEntry<String> {
  const _MenuSectionLabel(this.text);

  final String text;

  @override
  double get height => 30;

  @override
  bool represents(String? value) => false;

  @override
  State<_MenuSectionLabel> createState() => _MenuSectionLabelState();
}

class _MenuSectionLabelState extends State<_MenuSectionLabel> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(
        widget.text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 账号头像（网络图失败回退昵称首字）。
class _AccountAvatar extends StatelessWidget {
  const _AccountAvatar({this.avatarUrl, required this.nickname});

  final String? avatarUrl;
  final String nickname;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final url = avatarUrl?.trim();
    if (url != null && url.isNotEmpty) {
      // 头像仅 34px，按 dpr 降采样解码（原始头像图常为数百像素）
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final avatarPx = (34 * dpr).round();
      return ClipOval(
        child: Image.network(
          url,
          width: 34,
          height: 34,
          fit: BoxFit.cover,
          cacheWidth: avatarPx,
          cacheHeight: avatarPx,
          errorBuilder: (_, _, _) => _fallback(colorScheme),
        ),
      );
    }
    return _fallback(colorScheme);
  }

  Widget _fallback(ColorScheme colorScheme) {
    final letter = nickname.isNotEmpty ? nickname.characters.first : '?';
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Text(
        letter,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: colorScheme.primary,
        ),
      ),
    );
  }
}

/// 微型天气（顶栏头像左侧）：图标 + 温度，默认关闭（隐私优先）。
///
/// 位置来源：IP 自动定位（默认关）或设置页手动城市。开启后立即拉取并每
/// 30 分钟静默刷新，点击立即刷新；关闭时停表、零请求。数据仅展示在
/// 悬浮提示（城市 · 温度），不落盘。
class _WeatherMini extends ConsumerStatefulWidget {
  const _WeatherMini();

  @override
  ConsumerState<_WeatherMini> createState() => _WeatherMiniState();
}

class _WeatherMiniState extends ConsumerState<_WeatherMini> {
  /// 静默刷新间隔（微型组件不常驻请求）。
  static const _refreshInterval = Duration(minutes: 30);

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 当前位置配置（来自偏好）。
  ({bool autoLocate, String? city, String locateSource}) get _locator {
    final prefs = ref.read(appPrefsProvider);
    return (
      autoLocate: prefs.weatherAutoLocate,
      city: prefs.weatherCity,
      locateSource: prefs.weatherLocateSource,
    );
  }

  /// 开关/位置变化时同步：开启则立即拉取并启动周期刷新；关闭则停表。
  void _sync() {
    _timer?.cancel();
    _timer = null;
    if (!ref.read(appPrefsProvider).weatherEnabled) return;
    final loc = _locator;
    ref
        .read(weatherProvider)
        .refresh(
          autoLocate: loc.autoLocate,
          city: loc.city,
          locateSource: loc.locateSource,
        );
    _timer = Timer.periodic(_refreshInterval, (_) {
      final l = _locator;
      ref
          .read(weatherProvider)
          .refresh(
            autoLocate: l.autoLocate,
            city: l.city,
            locateSource: l.locateSource,
          );
    });
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(appPrefsProvider);
    // 偏好变化（开关 / 自动定位 / 定位来源 / 城市）→ 同步拉取与定时器
    ref.listen(appPrefsProvider, (prev, next) {
      if (prev?.weatherEnabled != next.weatherEnabled ||
          prev?.weatherAutoLocate != next.weatherAutoLocate ||
          prev?.weatherLocateSource != next.weatherLocateSource ||
          prev?.weatherCity != next.weatherCity) {
        _sync();
      }
    });
    if (!prefs.weatherEnabled) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final w = ref.watch(weatherProvider);
    final loc = _locator;

    final Widget content;
    final String tooltip;
    final now = w.now;
    if (now != null) {
      // win10 样式「图标 温度」：彩色语义图标 + 加粗温度
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(now.icon, size: 20, color: now.color),
          const SizedBox(width: 5),
          Text(
            '${now.tempC.round()}°',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
        ],
      );
      tooltip =
          '${now.city} · ${now.tempC.toStringAsFixed(1)}°C · '
          '${l10n.weatherRefresh}';
    } else if (w.loading) {
      // 首次拉取中：占位图标（避免闪烁）
      content = Icon(
        Icons.cloud_outlined,
        size: 18,
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
      );
      tooltip = '';
    } else if (w.error == weatherNoLocationError) {
      content = Icon(
        Icons.cloud_off_outlined,
        size: 18,
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
      );
      tooltip = l10n.weatherNoLocation;
    } else {
      content = Icon(
        Icons.cloud_off_outlined,
        size: 18,
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
      );
      tooltip = l10n.weatherUnavailable;
    }

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => ref
            .read(weatherProvider)
            .refresh(autoLocate: loc.autoLocate, city: loc.city),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: content,
        ),
      ),
    );
  }
}
