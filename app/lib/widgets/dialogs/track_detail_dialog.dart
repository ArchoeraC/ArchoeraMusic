/// 媒体详细信息弹窗（右键菜单「媒体详细信息」）。
///
/// 合并 SPlayer-Next PlayerData 的音质详情（编码/采样率/位深/比特率/声道）
/// 与 TagEditorDialog 的路径/文件大小字段：展示曲目标题、歌手、专辑、时长、
/// 来源平台、酷狗音质档、音频技术信息（流媒体服务器返回）与本地路径/大小。
library;

import 'package:flutter/material.dart';

import '../../services/netease/track.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../utils/format.dart';
import '../list/cover_image.dart';
import 's_dialog.dart';

/// 弹出媒体详细信息弹窗。
void showTrackDetailDialog(BuildContext context, {required Track track}) {
  SDialog.show(
    context,
    title: context.l10n.menuTrackDetail,
    width: 420,
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.commonClose),
      ),
    ],
    child: _TrackDetailBody(track: track),
  );
}

class _TrackDetailBody extends StatelessWidget {
  const _TrackDetailBody({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final t = track;

    // 预计算可空字段（集合字面量内不允许声明变量）
    final kugouQuality = _kugouQualityLabel(l10n, t);
    final q = t.quality;
    final fileSize = t.fileSize ?? _kugouBestSize(t);
    final localPath = t.localPath;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 头部：封面 + 标题 + 歌手
        Row(
          children: [
            CoverImage(cover: t.cover, width: 56, height: 56, radius: 10),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    t.artistNames.isNotEmpty
                        ? t.artistNames
                        : l10n.commonUnknownArtist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Divider(height: 1, color: scheme.outline.withValues(alpha: 0.3)),
        const SizedBox(height: 8),
        _field(
          scheme,
          Icons.album_outlined,
          l10n.trackDetailAlbum,
          t.album?.name.isNotEmpty == true
              ? t.album!.name
              : l10n.commonUnknownAlbum,
        ),
        _field(
          scheme,
          Icons.schedule,
          l10n.trackDetailDuration,
          formatMs(t.duration).isEmpty ? '-' : formatMs(t.duration),
        ),
        _field(
          scheme,
          Icons.cloud_outlined,
          l10n.trackDetailSource,
          _sourceLabel(l10n, t),
        ),
        // 酷狗音质档（含文件大小，如「无损 · 28.4MB」）
        if (kugouQuality != null)
          _field(scheme, Icons.high_quality_outlined, l10n.trackDetailQuality,
              kugouQuality),
        // 音频技术信息（流媒体服务器返回）
        if (q != null) ...[
          if (q.codec.isNotEmpty)
            _field(scheme, Icons.tune, l10n.trackDetailCodec, q.codec),
          if (q.sampleRate > 0)
            _field(scheme, Icons.multiline_chart, l10n.trackDetailSampleRate,
                '${q.sampleRate} Hz'),
          if (q.bitsPerSample > 0)
            _field(scheme, Icons.analytics_outlined, l10n.trackDetailBitDepth,
                '${q.bitsPerSample} bit'),
          if (q.bitRate > 0)
            _field(scheme, Icons.speed, l10n.trackDetailBitrate,
                '${q.bitRate} kbps'),
          _field(scheme, Icons.speaker, l10n.trackDetailChannels,
              '${q.channels}'),
        ],
        // 文件大小（服务器返回或酷狗品质表）
        if (fileSize != null && fileSize > 0)
          _field(scheme, Icons.insert_drive_file_outlined,
              l10n.trackDetailFileSize, _formatBytes(fileSize)),
        // 本地文件路径
        if (localPath != null && localPath.isNotEmpty)
          _field(scheme, Icons.folder_outlined, l10n.trackDetailPath,
              localPath),
      ],
    );
  }

  /// 单条信息行：左侧图标 + 标签，右侧值右对齐。
  Widget _field(ColorScheme scheme, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  /// 来源平台文案。
  String _sourceLabel(AppLocalizations l10n, Track t) => switch (t.source) {
        'netease' => l10n.brandNetease,
        'kugou' => l10n.brandKugou,
        'local' => l10n.trackSourceLocal,
        'streaming' => l10n.trackSourceStreaming,
        _ => t.source,
      };

  /// 酷狗最高可用音质档文案（含大小），无 kugou 信息返回 null。
  String? _kugouQualityLabel(AppLocalizations l10n, Track t) {
    final k = t.kugou;
    if (k == null) return null;
    const chain = ['hi-res', 'lossless', 'hq', 'sq', 'lq'];
    String? label;
    for (final level in chain) {
      if (k.hashFor(level) != null) {
        label = l10nQualityLabel(l10n, level);
        break;
      }
    }
    if (label == null) return null;
    final size = _kugouBestSize(t);
    return size == null ? label : '$label · ${_formatBytes(size)}';
  }

  /// 酷狗品质表中最大的文件大小（按高→低档序）。
  int? _kugouBestSize(Track t) {
    const order = ['flac24bit', 'flac', '320k', '128k'];
    final sizes = t.kugou?.sizes;
    if (sizes == null) return null;
    for (final q in order) {
      final s = sizes[q];
      if (s != null && s > 0) return s;
    }
    return null;
  }

  /// 字节数 → 人类可读（B / KB / MB / GB）。
  String _formatBytes(int bytes) {
    if (bytes <= 0) return '-';
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }
}
