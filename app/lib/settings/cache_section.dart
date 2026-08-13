import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../apis/runtime.dart';
import '../../l10n/l10n.dart';
import '../../services/cache/song_cache.dart';
import '../../services/liked/liked_cache.dart';
import '../../stores/app_prefs.dart';
import '../../widgets/common/toast.dart';
import '../../widgets/dialogs/s_dialog.dart';
import '../../widgets/player/s_controls.dart';
import 'settings_widgets.dart';

/// 存储分类下的缓存管理面板（对齐 SPlayer-Next 缓存管理：按介质分组、
/// 逐项清除 + 一键清空，破坏性操作均二次确认）。
///
/// 本项目实际可管理的缓存：
/// - **磁盘（SQLite）**：「我喜欢」列表缓存 [LikedCacheStore]（liked.db）
/// - **磁盘（文件）**：歌曲磁盘缓存 [SongCache]（流媒体歌曲文件级缓存，
///   开关 + MiB 上限在面板顶部）
/// - **内存（进程内）**：歌词内容 / 歌词匹配 / TTML 歌词缓存
///   （apis runtime 注入的进程内缓存，重启即失）与封面图片缓存
///   （Flutter [ImageCache]）
///
/// 曲库 library.db / 历史 history.db / 账号 user.db 属用户数据，不在此列。
class CacheSection extends ConsumerStatefulWidget {
  const CacheSection({super.key});

  @override
  ConsumerState<CacheSection> createState() => _CacheSectionState();
}

class _CacheSectionState extends ConsumerState<CacheSection> {
  int _likedRows = 0;
  int _likedBytes = 0;
  int _lyricCount = 0;
  int _matchCount = 0;
  int _ttmlCount = 0;
  int _imageBytes = 0;
  int _imageLive = 0;
  int _songBytes = 0;
  int _songFiles = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// 重算各缓存统计（「我喜欢」行数经后台 isolate 异步读 SQLite，
  /// 不阻塞 UI；其余统计同步）。
  void _refresh() {
    final file = File(LikedCacheStore.defaultDbPath());
    final imageCache = PaintingBinding.instance.imageCache;
    final songStats = SongCache.shared.stats();
    setState(() {
      _likedBytes = file.existsSync() ? file.lengthSync() : 0;
      _lyricCount = getRuntime().lyricCache.count;
      _matchCount = getRuntime().lyricMatchCache.count;
      _ttmlCount = getRuntime().lyricTtmlCache.count;
      _imageBytes = imageCache.currentSize;
      _imageLive = imageCache.liveImageCount;
      _songBytes = songStats.$1;
      _songFiles = songStats.$2;
    });
    LikedCacheStore.shared.rowCount().then((c) {
      if (mounted) setState(() => _likedRows = c);
    });
  }

  bool get _hasAny =>
      _likedRows > 0 ||
      _lyricCount > 0 ||
      _matchCount > 0 ||
      _ttmlCount > 0 ||
      _imageBytes > 0 ||
      _songFiles > 0;

  /// 二次确认后执行清除（对齐 SPlayer-Next：破坏性操作一律确认）。
  Future<void> _confirmClear(
    BuildContext context, {
    required String title,
    required String desc,
    required String confirmLabel,
    required String toastMsg,
    required VoidCallback action,
  }) async {
    final l10n = context.l10n;
    final ok = await SDialog.show<bool>(
      context,
      title: title,
      description: desc,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: confirmLabel,
          variant: SButtonVariant.error,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (ok != true) return;
    action();
    _refresh();
    if (context.mounted) {
      toast(toastMsg, type: ToastType.success);
    }
  }

  Future<void> _clearLiked() async {
    await LikedCacheStore.shared.clearAll();
  }

  /// 缓存上限开关：开启 → 按最小值立即生效；关闭（= 无上限）→ 弹窗
  /// 警告内存占用风险，确认后才真正写入（用户明确知情）。
  Future<void> _onLimitToggle(
    BuildContext context, {
    required bool enabled,
    required VoidCallback onEnable,
    required VoidCallback onDisable,
  }) async {
    if (enabled) {
      onEnable(); // 默认以最小值打开
      return;
    }
    final l10n = context.l10n;
    final ok = await SDialog.show<bool>(
      context,
      title: l10n.settingsCacheNoLimitConfirmTitle,
      description: l10n.settingsCacheNoLimitConfirmDesc,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.settingsCacheNoLimitConfirm,
          variant: SButtonVariant.error,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (ok == true) onDisable();
  }

  void _clearAll() {
    unawaited(_clearLiked());
    SongCache.shared.clear();
    getRuntime().lyricCache.clear();
    getRuntime().lyricMatchCache.clear();
    getRuntime().lyricTtmlCache.clear();
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    imageCache.clearLiveImages();
  }

  Widget _cacheRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String info,
    required bool enabled,
    required VoidCallback onClear,
  }) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return SettingTile(
      icon: icon,
      title: title,
      subtitle: info,
      trailing: IconButton(
        tooltip: l10n.settingsCacheClear,
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        onPressed: enabled ? onClear : null,
        icon: Icon(
          Icons.delete_outline,
          color: enabled
              ? scheme.error
              : scheme.onSurface.withValues(alpha: 0.25),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final likedPath = LikedCacheStore.defaultDbPath();
    final prefs = ref.watch(appPrefsProvider);
    final notifier = ref.read(appPrefsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 歌曲磁盘缓存：开关 + 上限（MiB）+ 统计/清除
        SettingSection(
          title: l10n.settingsSongCache,
          note: l10n.settingsSongCacheNote,
          children: [
            SettingSwitchTile(
              icon: prefs.songCacheEnabled
                  ? Icons.offline_pin
                  : Icons.offline_pin_outlined,
              title: l10n.settingsSongCache,
              subtitle: prefs.songCacheEnabled
                  ? l10n.settingsSongCacheOn
                  : l10n.settingsSongCacheOff,
              value: prefs.songCacheEnabled,
              onChanged: notifier.setSongCacheEnabled,
            ),
            if (prefs.songCacheEnabled)
              SettingSliderTile(
                icon: Icons.storage_outlined,
                title: l10n.settingsSongCacheLimitTitle,
                subtitle:
                    '${prefs.songCacheLimitMiB} MiB · ${_formatBytes(prefs.songCacheLimitMiB * 1024 * 1024)}',
                value: prefs.songCacheLimitMiB.toDouble(),
                min: songCacheLimitMinMiB.toDouble(),
                max: songCacheLimitMaxMiB.toDouble(),
                divisions:
                    (songCacheLimitMaxMiB - songCacheLimitMinMiB) ~/
                    songCacheLimitStepMiB,
                label: '${prefs.songCacheLimitMiB} MiB',
                onChanged: (v) => notifier.setSongCacheLimitMiB(v.round()),
              ),
            _cacheRow(
              context,
              icon: Icons.audiotrack_outlined,
              title: l10n.settingsSongCache,
              info:
                  '${_formatBytes(_songBytes)} · ${l10n.settingsCacheSongs(_songFiles)}',
              enabled: _songFiles > 0,
              onClear: () => _confirmClear(
                context,
                title: l10n.settingsCacheClearConfirmTitle(
                  l10n.settingsSongCache,
                ),
                desc: l10n.settingsCacheClearConfirmDesc,
                confirmLabel: l10n.settingsCacheClear,
                toastMsg: l10n.toastCacheCleared(l10n.settingsSongCache),
                action: () => SongCache.shared.clear(),
              ),
            ),
          ],
        ),
        // 操作行：刷新统计 + 一键清空
        SettingSection(
          title: l10n.settingsSectionCache,
          note: l10n.settingsCacheNote,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              child: Row(
                children: [
                  SButton(
                    label: l10n.settingsCacheRefresh,
                    icon: Icons.refresh,
                    variant: SButtonVariant.ghost,
                    size: SButtonSize.small,
                    onPressed: _refresh,
                  ),
                  const Spacer(),
                  SButton(
                    label: l10n.settingsCacheClearAll,
                    icon: Icons.delete_sweep_outlined,
                    variant: SButtonVariant.error,
                    size: SButtonSize.small,
                    onPressed: _hasAny
                        ? () => _confirmClear(
                            context,
                            title: l10n.settingsCacheClearAllConfirmTitle,
                            desc: l10n.settingsCacheClearAllConfirmDesc,
                            confirmLabel: l10n.settingsCacheClearAll,
                            toastMsg: l10n.toastCacheAllCleared,
                            action: _clearAll,
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
        // 数据库缓存（磁盘）
        SettingSection(
          title: l10n.settingsCacheGroupDisk,
          children: [
            _cacheRow(
              context,
              icon: Icons.favorite_outline,
              title: l10n.settingsCacheLiked,
              info:
                  '$likedPath\n${_formatBytes(_likedBytes)} · ${l10n.settingsCacheEntries(_likedRows)}',
              enabled: _likedRows > 0,
              onClear: () => _confirmClear(
                context,
                title: l10n.settingsCacheClearConfirmTitle(
                  l10n.settingsCacheLiked,
                ),
                desc: l10n.settingsCacheClearConfirmDesc,
                confirmLabel: l10n.settingsCacheClear,
                toastMsg: l10n.toastCacheCleared(l10n.settingsCacheLiked),
                action: _clearLiked,
              ),
            ),
          ],
        ),
        // 内存缓存（进程内）
        SettingSection(
          title: l10n.settingsCacheGroupMem,
          children: [
            // 歌词缓存上限（默认最小值开启；关闭 = 无上限，弹窗警告）
            SettingSwitchTile(
              icon: Icons.data_usage_outlined,
              title: l10n.settingsCacheLimitLyric,
              subtitle: prefs.lyricCacheLimitMiB == null
                  ? l10n.settingsCacheLimitUnlimited
                  : '${prefs.lyricCacheLimitMiB} MiB',
              value: prefs.lyricCacheLimitMiB != null,
              onChanged: (v) => _onLimitToggle(
                context,
                enabled: v,
                onEnable: () =>
                    notifier.setLyricCacheLimitMiB(lyricCacheLimitMinMiB),
                onDisable: () => notifier.setLyricCacheLimitMiB(0),
              ),
            ),
            if (prefs.lyricCacheLimitMiB != null)
              SettingSliderTile(
                icon: Icons.tune,
                title: l10n.settingsCacheLimitLyric,
                subtitle: '${prefs.lyricCacheLimitMiB} MiB',
                value: prefs.lyricCacheLimitMiB!.toDouble(),
                min: lyricCacheLimitMinMiB.toDouble(),
                max: lyricCacheLimitMaxMiB.toDouble(),
                divisions: lyricCacheLimitMaxMiB - lyricCacheLimitMinMiB,
                label: '${prefs.lyricCacheLimitMiB} MiB',
                onChanged: (v) => notifier.setLyricCacheLimitMiB(v.round()),
              ),
            // 封面图片缓存上限（默认最小值开启；关闭 = 无上限，弹窗警告）
            SettingSwitchTile(
              icon: Icons.photo_library_outlined,
              title: l10n.settingsCacheLimitCover,
              subtitle: prefs.imageCacheLimitMiB == null
                  ? l10n.settingsCacheLimitUnlimited
                  : '${prefs.imageCacheLimitMiB} MiB',
              value: prefs.imageCacheLimitMiB != null,
              onChanged: (v) => _onLimitToggle(
                context,
                enabled: v,
                onEnable: () =>
                    notifier.setImageCacheLimitMiB(imageCacheLimitMinMiB),
                onDisable: () => notifier.setImageCacheLimitMiB(0),
              ),
            ),
            if (prefs.imageCacheLimitMiB != null)
              SettingSliderTile(
                icon: Icons.tune,
                title: l10n.settingsCacheLimitCover,
                subtitle: '${prefs.imageCacheLimitMiB} MiB',
                value: prefs.imageCacheLimitMiB!.toDouble(),
                min: imageCacheLimitMinMiB.toDouble(),
                max: imageCacheLimitMaxMiB.toDouble(),
                divisions:
                    (imageCacheLimitMaxMiB - imageCacheLimitMinMiB) ~/
                    imageCacheLimitStepMiB,
                label: '${prefs.imageCacheLimitMiB} MiB',
                onChanged: (v) => notifier.setImageCacheLimitMiB(v.round()),
              ),
            _cacheRow(
              context,
              icon: Icons.lyrics_outlined,
              title: l10n.settingsCacheLyric,
              info: l10n.settingsCacheEntries(_lyricCount),
              enabled: _lyricCount > 0,
              onClear: () => _confirmClear(
                context,
                title: l10n.settingsCacheClearConfirmTitle(
                  l10n.settingsCacheLyric,
                ),
                desc: l10n.settingsCacheClearConfirmDesc,
                confirmLabel: l10n.settingsCacheClear,
                toastMsg: l10n.toastCacheCleared(l10n.settingsCacheLyric),
                action: getRuntime().lyricCache.clear,
              ),
            ),
            _cacheRow(
              context,
              icon: Icons.compare_arrows_outlined,
              title: l10n.settingsCacheLyricMatch,
              info: l10n.settingsCacheEntries(_matchCount),
              enabled: _matchCount > 0,
              onClear: () => _confirmClear(
                context,
                title: l10n.settingsCacheClearConfirmTitle(
                  l10n.settingsCacheLyricMatch,
                ),
                desc: l10n.settingsCacheClearConfirmDesc,
                confirmLabel: l10n.settingsCacheClear,
                toastMsg: l10n.toastCacheCleared(l10n.settingsCacheLyricMatch),
                action: getRuntime().lyricMatchCache.clear,
              ),
            ),
            _cacheRow(
              context,
              icon: Icons.text_snippet_outlined,
              title: l10n.settingsCacheLyricTtml,
              info: l10n.settingsCacheEntries(_ttmlCount),
              enabled: _ttmlCount > 0,
              onClear: () => _confirmClear(
                context,
                title: l10n.settingsCacheClearConfirmTitle(
                  l10n.settingsCacheLyricTtml,
                ),
                desc: l10n.settingsCacheClearConfirmDesc,
                confirmLabel: l10n.settingsCacheClear,
                toastMsg: l10n.toastCacheCleared(l10n.settingsCacheLyricTtml),
                action: getRuntime().lyricTtmlCache.clear,
              ),
            ),
            _cacheRow(
              context,
              icon: Icons.image_outlined,
              title: l10n.settingsCacheCover,
              info:
                  '${_formatBytes(_imageBytes)} · ${l10n.settingsCacheImages(_imageLive)}',
              enabled: _imageBytes > 0,
              onClear: () => _confirmClear(
                context,
                title: l10n.settingsCacheClearConfirmTitle(
                  l10n.settingsCacheCover,
                ),
                desc: l10n.settingsCacheClearConfirmDesc,
                confirmLabel: l10n.settingsCacheClear,
                toastMsg: l10n.toastCacheCleared(l10n.settingsCacheCover),
                action: () {
                  final imageCache = PaintingBinding.instance.imageCache;
                  imageCache.clear();
                  imageCache.clearLiveImages();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
  }
}
