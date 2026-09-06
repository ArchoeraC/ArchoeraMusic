// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

// ── 存储 ──────────────────────────────────────────────────────────────

/// 存储分类：数据目录 / 曲库数据库 / 用户数据库路径展示与复制。
class StorageSection extends ConsumerStatefulWidget {
  const StorageSection({super.key});

  @override
  ConsumerState<StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends ConsumerState<StorageSection> {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final dataDir = resolveDataDir();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsSectionFileLocation,
          children: [
            SettingTile(
              icon: Icons.folder_outlined,
              title: l10n.settingsDataDir,
              subtitle: dataDir,
              trailing: SettingCopyButton(
                value: dataDir,
                label: l10n.settingsDataDir,
              ),
            ),
            SettingTile(
              icon: Icons.album_outlined,
              title: l10n.settingsLibraryDb,
              subtitle: '$dataDir/database/library.db',
              trailing: SettingCopyButton(
                value: '$dataDir/database/library.db',
                label: l10n.settingsLibraryDbLabel,
              ),
            ),
            SettingTile(
              icon: Icons.key_outlined,
              title: l10n.settingsUserDb,
              subtitle: '$dataDir/database/user.db',
              trailing: SettingCopyButton(
                value: '$dataDir/database/user.db',
                label: l10n.settingsUserDbLabel,
              ),
            ),
            SettingTile(
              icon: Icons.history,
              title: l10n.settingsHistoryDb,
              subtitle: '$dataDir/database/history.db',
              trailing: SettingCopyButton(
                value: '$dataDir/database/history.db',
                label: l10n.settingsHistoryDbLabel,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
