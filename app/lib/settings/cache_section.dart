import 'dart:io';

import 'package:flutter/material.dart';

import '../../apis/runtime.dart';
import '../../l10n/l10n.dart';
import '../../services/liked/liked_cache.dart';
import '../../widgets/common/toast.dart';
import '../../widgets/dialogs/s_dialog.dart';
import '../../widgets/player/s_controls.dart';
import 'settings_widgets.dart';

/// 存储分类下的缓存管理面板（对齐 SPlayer-Next 缓存管理：按介质分组、
/// 逐项清除 + 一键清空，破坏性操作均二次确认）。
///
/// 本项目实际可管理的缓存：
/// - **磁盘（SQLite）**：「我喜欢」列表缓存 [LikedCacheStore]（liked.db）
/// - **内存（进程内）**：歌词内容 / 歌词匹配 / TTML 歌词缓存
///   （apis runtime 注入的进程内缓存，重启即失）与封面图片缓存
///   （Flutter [ImageCache]）
///
/// 曲库 library.db / 历史 history.db / 账号 user.db 属用户数据，不在此列。
class CacheSection extends StatefulWidget {
  const CacheSection({super.key});

  @override
  State<CacheSection> createState() => _CacheSectionState();
}

class _CacheSectionState extends State<CacheSection> {
  int _likedRows = 0;
  int _likedBytes = 0;
  int _lyricCount = 0;
  int _matchCount = 0;
  int _ttmlCount = 0;
  int _imageBytes = 0;
  int _imageLive = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// 重算各缓存统计（同步：SQLite COUNT + 内存 map 计数 + ImageCache 字节）。
  void _refresh() {
    final store = LikedCacheStore.shared;
    final file = File(LikedCacheStore.defaultDbPath());
    final imageCache = PaintingBinding.instance.imageCache;
    setState(() {
      _likedRows = store.rowCount();
      _likedBytes = file.existsSync() ? file.lengthSync() : 0;
      _lyricCount = getRuntime().lyricCache.count;
      _matchCount = getRuntime().lyricMatchCache.count;
      _ttmlCount = getRuntime().lyricTtmlCache.count;
      _imageBytes = imageCache.currentSize;
      _imageLive = imageCache.liveImageCount;
    });
  }

  bool get _hasAny =>
      _likedRows > 0 ||
      _lyricCount > 0 ||
      _matchCount > 0 ||
      _ttmlCount > 0 ||
      _imageBytes > 0;

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

  void _clearLiked() => LikedCacheStore.shared.clearAll();

  void _clearAll() {
    _clearLiked();
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
