// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Bilibili 分P选择对话框。
library;

import 'package:material_ui/material_ui.dart';

import '../../apis/bilibili/core/types.dart';
import '../../l10n/l10n.dart';
import '../../services/bilibili/bilibili_api.dart';
import '../../services/netease/track.dart';
import 's_dialog.dart';

/// 选择分P；返回 null = 用户取消。
Future<Track?> showBilibiliPartsDialog(
  BuildContext context,
  Track track,
  BilibiliVideoDetail detail, {
  required BilibiliApi api,
}) {
  final l10n = context.l10n;
  return SDialog.show<Track>(
    context,
    title: l10n.bilibiliSelectPart,
    description: detail.title,
    width: 520,
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(l10n.commonCancel),
      ),
    ],
    child: _PartsList(detail: detail, api: api),
  );
}

class _PartsList extends StatelessWidget {
  const _PartsList({required this.detail, required this.api});

  final BilibiliVideoDetail detail;
  final BilibiliApi api;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final part in detail.parts)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: CircleAvatar(
              radius: 14,
              backgroundColor: scheme.primary.withValues(alpha: 0.12),
              child: Text(
                '${part.page}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ),
            title: Text(
              part.title.isEmpty ? 'P${part.page}' : part.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: part.durationMs > 0
                ? Text(_formatDuration(part.durationMs))
                : null,
            onTap: () =>
                Navigator.of(context).pop(api.trackForPart(detail, part)),
          ),
      ],
    );
  }
}

String _formatDuration(int ms) {
  final total = (ms / 1000).round();
  final minutes = total ~/ 60;
  final seconds = total % 60;
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (hours > 0) {
    return '$hours:${rest.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
