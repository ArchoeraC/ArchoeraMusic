import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../services/scanner/library_store.dart';
import '../../services/scanner/local_track.dart';
import '../../services/scraper/scrape_controller.dart';
import '../../stores/app_prefs.dart';
import '../../stores/data_dir.dart';
import '../common/anim.dart';
import '../common/toast.dart';
import '../dialogs/folder_manager.dart';
import '../dialogs/s_dialog.dart';
import '../player/s_controls.dart';

/// 音乐库页顶栏：标题 + 状态区 + 操作行（播放全部 / 扫描 / 刮削 / 更多）
/// + 搜索框。
///
/// 从 LibraryPage.build 拆出：自读 store/scrape 状态，目录/统计/刮削等
/// 对话框与偏好读写都在本组件内完成，页面只剩列表体（降低嵌套深度）。
class LibraryHeader extends ConsumerWidget {
  const LibraryHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(libraryStoreProvider);
    final scrape = ref.watch(scrapeControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final notifier = ref.read(libraryStoreProvider.notifier);
    final tracks = state.filteredTracks.map(trackFromRow).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题 + 统计 / 扫描进度
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                l10n.sidebarLibrary,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(width: 14),
              _buildStatus(context, state, scheme, l10n),
            ],
          ),
          const SizedBox(height: 14),
          // 操作行 + 搜索
          Row(
            children: [
              SButton(
                label: l10n.commonPlayAll,
                icon: Icons.play_arrow_rounded,
                variant: SButtonVariant.primary,
                onPressed: tracks.isEmpty
                    ? null
                    : () => _playAll(context, ref, tracks),
              ),
              const SizedBox(width: 8),
              // 扫描（旋转动画）
              SizedBox(
                width: 36,
                height: 36,
                child: AnimatedRotation(
                  turns: state.scanning ? 1 : 0,
                  duration: animDuration(
                    context,
                    const Duration(milliseconds: 400),
                  ),
                  curve: Curves.linear,
                  child: SButton(
                    label: '',
                    circle: true,
                    icon: Icons.refresh,
                    variant: SButtonVariant.secondary,
                    onPressed: state.scanning
                        ? notifier.cancelScan
                        : (state.scanDirs.isEmpty
                              ? null
                              : () => notifier.startScan()),
                    loading: state.scanning,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 刮削（简化入口：运行中变停止按钮可取消；详细参数见设置 → 刮削）
              SizedBox(
                width: 36,
                height: 36,
                child: SButton(
                  label: '',
                  circle: true,
                  icon: scrape.scraping ? Icons.stop : Icons.auto_fix_high,
                  variant: scrape.scraping
                      ? SButtonVariant.error
                      : SButtonVariant.secondary,
                  onPressed: () => _toggleScrape(context, ref),
                ),
              ),
              const SizedBox(width: 8),
              // 更多菜单
              PopupMenuButton<String>(
                tooltip: l10n.commonMore,
                position: PopupMenuPosition.under,
                offset: const Offset(0, 4),
                // 性能模式：菜单直出，无淡入/弹出动效
                popUpAnimationStyle: noAnim(context)
                    ? AnimationStyle.noAnimation
                    : null,
                onSelected: (key) {
                  switch (key) {
                    case 'folders':
                      _openFolders(context);
                      break;
                    case 'stats':
                      _openMediaStats(context, state);
                      break;
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'folders',
                    height: 40,
                    child: Row(
                      children: [
                        Icon(Icons.folder_outlined, size: 17),
                        SizedBox(width: 10),
                        Text(l10n.libraryScanDirs),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'stats',
                    height: 40,
                    child: Row(
                      children: [
                        Icon(Icons.pie_chart_outline, size: 17),
                        SizedBox(width: 10),
                        Text(l10n.libraryMediaStats),
                      ],
                    ),
                  ),
                ],
                child: const SizedBox(
                  width: 36,
                  height: 36,
                  child: Center(child: Icon(Icons.more_horiz, size: 20)),
                ),
              ),
              const Spacer(),
              SInput(
                width: 190,
                hintText: l10n.librarySearchHint,
                prefixIcon: Icons.search,
                clearable: true,
                onChanged: (q) => notifier.setSearchQuery(q),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 标题旁的状态区：扫描进度 / 曲目统计（对齐原项目 Transition 切换）。
  Widget _buildStatus(
    BuildContext context,
    LibraryState state,
    ColorScheme scheme,
    AppLocalizations l10n,
  ) {
    final Widget child;
    if (state.scanning) {
      final percent = state.scanPercent;
      child = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            percent == null
                ? (state.scanCurrent.isEmpty
                      ? l10n.libraryScanningFiles
                      : state.scanCurrent)
                : '${(percent * 100).toStringAsFixed(0)}%'
                      ' · ${state.scanned}/${state.total}',
            style: TextStyle(
              fontSize: 13,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
            ),
          ),
        ],
      );
    } else if (state.initialized && state.tracks.isNotEmpty) {
      final size = _formatSize(state.totalSizeBytes);
      child = Text(
        l10n.libraryTrackCount(
          state.tracks.length,
          size.isEmpty ? '' : ' · $size',
        ),
        style: TextStyle(
          fontSize: 13,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
        ),
      );
    } else {
      child = const SizedBox.shrink();
    }
    return AnimatedSwitcher(
      duration: animDuration(context, const Duration(milliseconds: 200)),
      child: child,
    );
  }

  void _playAll(BuildContext context, WidgetRef ref, List<Track> tracks) {
    final l10n = context.l10n;
    if (tracks.isEmpty) return;
    try {
      ref.read(playbackProvider.notifier).playQueue(tracks);
    } catch (e) {
      _toast(context, l10n.toastPlayFailed('$e'));
    }
  }

  /// 刮削简化入口：运行中 → 取消；空闲 → 立即刮削。
  /// 目录取偏好配置，留空跟随媒体库扫描目录；数据源开关在
  /// 设置 → 刮削 中详细配置（这里用偏好默认值）。
  void _toggleScrape(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final notifier = ref.read(scrapeControllerProvider.notifier);
    if (ref.read(scrapeControllerProvider).scraping) {
      notifier.cancel();
      return;
    }
    final prefs = ref.read(appPrefsProvider);
    var dirs = prefs.scrapeDirs;
    if (dirs.isEmpty) dirs = scanDirs();
    if (dirs.isEmpty) {
      _toast(context, l10n.toastScrapeNoDirs);
      return;
    }
    notifier.start(
      dirs: dirs,
      dbPath: '${resolveDataDir()}/scraper-state.db',
      sources: ScrapeSources(
        musicBrainz: prefs.scrapeUseMusicBrainz,
        deezer: prefs.scrapeUseDeezer,
        itunes: prefs.scrapeUseItunes,
        netease: prefs.scrapeUseNetease,
        qqMusic: prefs.scrapeUseQQMusic,
        kugou: prefs.scrapeUseKugou,
        kuwo: prefs.scrapeUseKuwo,
        migu: prefs.scrapeUseMigu,
        acoustId: prefs.scrapeUseAcoustID,
      ),
    );
    _toast(context, l10n.toastScrapeStarted);
  }

  void _openFolders(BuildContext context) {
    final l10n = context.l10n;
    SDialog.show(
      context,
      title: l10n.libraryScanDirs,
      description: l10n.libraryScanDirsDesc,
      child: const FolderManager(),
      actions: [
        SButton(
          label: l10n.commonDone,
          variant: SButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  void _openMediaStats(BuildContext context, LibraryState state) {
    final l10n = context.l10n;
    SDialog.show(
      context,
      title: l10n.libraryMediaStats,
      description: l10n.libraryMediaStatsDesc,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _statRow(
            context,
            l10n.libraryStatTracks,
            l10n.libraryStatTrackCount(state.tracks.length),
          ),
          _statRow(
            context,
            l10n.libraryStatDuration,
            _formatDuration(
              state.tracks.fold(0, (sum, t) => sum + t.durationMs),
              l10n,
            ),
          ),
          _statRow(
            context,
            l10n.libraryStatSize,
            _formatSize(state.totalSizeBytes),
          ),
          _statRow(
            context,
            l10n.libraryScanDirs,
            l10n.libraryScanDirCount(state.scanDirs.length),
          ),
        ],
      ),
      actions: [
        SButton(
          label: l10n.commonClose,
          variant: SButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Widget _statRow(BuildContext context, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
  }

  String _formatDuration(int ms, AppLocalizations l10n) {
    final totalSec = ms ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    if (h > 0) return l10n.libraryHoursMinutes(h, m);
    if (m > 0) return l10n.libraryMinutes(m);
    return l10n.librarySeconds(s);
  }

  void _toast(BuildContext context, String msg) {
    if (!context.mounted) return;
    toast(msg);
  }
}
