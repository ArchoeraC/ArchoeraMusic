// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';
import '../player/s_controls.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

/// 空库状态：无目录 → 引导添加；有目录未扫描 → 引导扫描。
class LibraryEmptyState extends StatelessWidget {
  const LibraryEmptyState({
    super.key,
    required this.hasDirs,
    required this.scanning,
    required this.onAddFolder,
  });

  final bool hasDirs;
  final bool scanning;
  final VoidCallback onAddFolder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              EtaIcons.music2Outline,
              size: 34,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            hasDirs ? l10n.libraryEmptyWaitScan : l10n.libraryEmpty,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            hasDirs ? l10n.libraryEmptyScanHint : l10n.libraryEmptyAddHint,
            style: TextStyle(
              fontSize: 12.5,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 20),
          SButton(
            label: hasDirs ? l10n.libraryScanNow : l10n.libraryAddFolder,
            icon: hasDirs ? EtaIcons.refresh : EtaIcons.newFolderOutline,
            variant: SButtonVariant.primary,
            loading: scanning,
            onPressed: scanning ? null : onAddFolder,
          ),
        ],
      ),
    );
  }
}
