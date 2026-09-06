// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../track_detail_dialog.dart';

class _TrackDetailBody extends StatelessWidget {
  const _TrackDetailBody({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final t = track;

    final kugouQuality = _kugouQualityLabel(l10n, t);
    final q = t.quality;
    final fileSize = t.fileSize ?? _kugouBestSize(t);
    final localPath = t.localPath;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TrackDetailHeader(track: t, theme: theme, scheme: scheme, l10n: l10n),
        const SizedBox(height: 16),
        Divider(height: 1, color: scheme.outline.withValues(alpha: 0.3)),
        const SizedBox(height: 8),
        _TrackDetailField(
          scheme: scheme,
          icon: Icons.album_outlined,
          label: l10n.trackDetailAlbum,
          value: t.album?.name.isNotEmpty == true
              ? t.album!.name
              : l10n.commonUnknownAlbum,
        ),
        _TrackDetailField(
          scheme: scheme,
          icon: Icons.schedule,
          label: l10n.trackDetailDuration,
          value: formatMs(t.duration).isEmpty ? '-' : formatMs(t.duration),
        ),
        _TrackDetailField(
          scheme: scheme,
          icon: Icons.cloud_outlined,
          label: l10n.trackDetailSource,
          value: _sourceLabel(l10n, t),
        ),
        if (kugouQuality != null)
          _TrackDetailField(
            scheme: scheme,
            icon: Icons.high_quality_outlined,
            label: l10n.trackDetailQuality,
            value: kugouQuality,
          ),
        if (q != null) ...[
          if (q.codec.isNotEmpty)
            _TrackDetailField(
              scheme: scheme,
              icon: Icons.tune,
              label: l10n.trackDetailCodec,
              value: q.codec,
            ),
          if (q.sampleRate > 0)
            _TrackDetailField(
              scheme: scheme,
              icon: Icons.multiline_chart,
              label: l10n.trackDetailSampleRate,
              value: '${q.sampleRate} Hz',
            ),
          if (q.bitsPerSample > 0)
            _TrackDetailField(
              scheme: scheme,
              icon: Icons.analytics_outlined,
              label: l10n.trackDetailBitDepth,
              value: '${q.bitsPerSample} bit',
            ),
          if (q.bitRate > 0)
            _TrackDetailField(
              scheme: scheme,
              icon: Icons.speed,
              label: l10n.trackDetailBitrate,
              value: '${q.bitRate} kbps',
            ),
          _TrackDetailField(
            scheme: scheme,
            icon: Icons.speaker,
            label: l10n.trackDetailChannels,
            value: '${q.channels}',
          ),
        ],
        if (fileSize != null && fileSize > 0)
          _TrackDetailField(
            scheme: scheme,
            icon: Icons.insert_drive_file_outlined,
            label: l10n.trackDetailFileSize,
            value: _formatBytes(fileSize),
          ),
        if (localPath != null && localPath.isNotEmpty)
          _TrackDetailField(
            scheme: scheme,
            icon: Icons.folder_outlined,
            label: l10n.trackDetailPath,
            value: localPath,
          ),
      ],
    );
  }

  String _sourceLabel(AppLocalizations l10n, Track t) => switch (t.source) {
    'netease' => l10n.brandNetease,
    'kugou' => l10n.brandKugou,
    'local' => l10n.trackSourceLocal,
    'streaming' => l10n.trackSourceStreaming,
    _ => t.source,
  };

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

class _TrackDetailHeader extends StatelessWidget {
  const _TrackDetailHeader({
    required this.track,
    required this.theme,
    required this.scheme,
    required this.l10n,
  });

  final Track track;
  final ThemeData theme;
  final ColorScheme scheme;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CoverImage(cover: track.cover, width: 56, height: 56, radius: 10),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                track.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                track.artistNames.isNotEmpty
                    ? track.artistNames
                    : l10n.commonUnknownArtist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TrackDetailField extends StatelessWidget {
  const _TrackDetailField({
    required this.scheme,
    required this.icon,
    required this.label,
    required this.value,
  });

  final ColorScheme scheme;
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
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
}
