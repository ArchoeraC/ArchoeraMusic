// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

// ── 下载 ──────────────────────────────────────────────────────────────

/// 下载分类（开发者模式可见）：根目录 / 文件名模板 / 音质 / 并发 /
/// 分组策略 / 限速 / 记录上限。
class DownloadSection extends ConsumerStatefulWidget {
  const DownloadSection({super.key});

  @override
  ConsumerState<DownloadSection> createState() => _DownloadSectionState();
}

class _DownloadSectionState extends ConsumerState<DownloadSection> {
  late final TextEditingController _downloadRootCtrl;
  late final TextEditingController _downloadTemplateCtrl;
  double? _downloadConcurrentDraft;
  double? _downloadSpeedDraft;
  double? _downloadHistoryLimitDraft;

  @override
  void initState() {
    super.initState();
    _downloadRootCtrl = TextEditingController(
      text: ref.read(appPrefsProvider).downloadRoot,
    );
    _downloadTemplateCtrl = TextEditingController(
      text: ref.read(appPrefsProvider).downloadFilenameTemplate,
    );
  }

  @override
  void dispose() {
    _downloadRootCtrl.dispose();
    _downloadTemplateCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final prefs = ref.watch(appPrefsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsSectionDir,
          children: [
            SettingPathFieldCard(
              icon: EtaIcons.folderOutline,
              ctrl: _downloadRootCtrl,
              hint: l10n.settingsDownloadRootHint,
              save: (v) => _saveDownloadRoot(v, l10n),
              restoreDefault: defaultDownloadRoot,
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionFilename,
          note: l10n.settingsDownloadTemplateNote,
          children: [
            SettingPathFieldCard(
              icon: EtaIcons.fontSizeOutline,
              ctrl: _downloadTemplateCtrl,
              hint: l10n.settingsDownloadTemplateHint,
              save: (v) => _saveDownloadTemplate(v, l10n),
              restoreDefault: () => '{artist} - {title}',
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionQuality,
          note: l10n.settingsDownloadQualityNote,
          children: [
            SettingTile(
              icon: EtaIcons.highQualityOutline,
              title: l10n.settingsDownloadQuality,
              subtitle: l10n.settingsDownloadQualityDesc(
                l10nQualityLabel(l10n, prefs.downloadQuality),
              ),
              trailing: SSegmented<String>(
                options: [
                  for (final q in downloadQualityLevels)
                    SSegmentedOption(q, l10nQualityLabel(l10n, q)),
                ],
                selected: prefs.downloadQuality,
                onChanged: (q) =>
                    ref.read(appPrefsProvider.notifier).setDownload(quality: q),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionConcurrent,
          children: [
            SettingSliderTile(
              icon: EtaIcons.dashboard4Outline,
              title: l10n.settingsDownloadConcurrent,
              subtitle: l10n.settingsDownloadConcurrentDesc(
                prefs.downloadMaxConcurrent,
              ),
              value:
                  _downloadConcurrentDraft ??
                  prefs.downloadMaxConcurrent.toDouble(),
              min: 1,
              max: 5,
              divisions: 4,
              label:
                  '${(_downloadConcurrentDraft ?? prefs.downloadMaxConcurrent.toDouble()).round()}',
              width: 160,
              onChanged: (v) => setState(() => _downloadConcurrentDraft = v),
              onChangeEnd: (v) {
                setState(() => _downloadConcurrentDraft = null);
                ref
                    .read(appPrefsProvider.notifier)
                    .setDownload(maxConcurrent: v.round());
              },
            ),
            SettingTile(
              icon: EtaIcons.foldersOutline,
              title: l10n.settingsDownloadGrouping,
              subtitle: switch (prefs.downloadSubdirStrategy) {
                0 => l10n.settingsGroupingFlat,
                1 => l10n.settingsGroupingPlatform,
                _ => l10n.settingsGroupingArtist,
              },
              trailing: SSegmented<int>(
                options: [
                  SSegmentedOption(0, l10n.settingsGroupingFlatLabel),
                  SSegmentedOption(1, l10n.settingsGroupingPlatformLabel),
                  SSegmentedOption(2, l10n.settingsGroupingArtistLabel),
                ],
                selected: prefs.downloadSubdirStrategy,
                onChanged: (v) => ref
                    .read(appPrefsProvider.notifier)
                    .setDownload(subdirStrategy: v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionSpeedLimit,
          note: l10n.settingsSpeedNote,
          children: [
            SettingSliderTile(
              icon: EtaIcons.dashboard4Outline,
              title: l10n.settingsDownloadSpeedLimit,
              subtitle: prefs.downloadSpeedLimit <= 0
                  ? l10n.settingsSpeedUnlimited
                  : l10n.settingsSpeedLimited(
                      _fmtSpeedLabel(prefs.downloadSpeedLimit, l10n),
                    ),
              value:
                  _downloadSpeedDraft ??
                  (prefs.downloadSpeedLimit / (1024 * 1024)).toDouble(),
              min: 0,
              max: 20,
              divisions: 40,
              label: _downloadSpeedDraft != null && _downloadSpeedDraft! <= 0
                  ? l10n.settingsSpeedUnlimitedLabel
                  : l10n.settingsSpeedMbps(
                      ((_downloadSpeedDraft ??
                              prefs.downloadSpeedLimit / (1024 * 1024)))
                          .toStringAsFixed(1),
                    ),
              width: 160,
              onChanged: (v) => setState(() => _downloadSpeedDraft = v),
              onChangeEnd: (v) {
                setState(() => _downloadSpeedDraft = null);
                ref
                    .read(appPrefsProvider.notifier)
                    .setDownload(speedLimit: (v * 1024 * 1024).round());
              },
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionHistory,
          note: l10n.settingsDownloadHistoryNote,
          children: [
            SettingSliderTile(
              icon: EtaIcons.historyOutline,
              title: l10n.settingsDownloadHistoryLimit,
              subtitle: l10n.settingsDownloadHistoryDesc(
                prefs.downloadHistoryLimit,
              ),
              value:
                  _downloadHistoryLimitDraft ??
                  prefs.downloadHistoryLimit.toDouble(),
              min: 10,
              max: 500,
              divisions: 49,
              label: l10n.settingsDownloadHistoryCount(
                (_downloadHistoryLimitDraft ??
                        prefs.downloadHistoryLimit.toDouble())
                    .round(),
              ),
              width: 160,
              onChanged: (v) => setState(() => _downloadHistoryLimitDraft = v),
              onChangeEnd: (v) {
                setState(() => _downloadHistoryLimitDraft = null);
                ref
                    .read(appPrefsProvider.notifier)
                    .setDownload(historyLimit: v.round());
              },
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionFingerprint,
          note: l10n.settingsFingerprintNote,
          children: [
            SettingSwitchTile(
              icon: EtaIcons.publishedWithChangesOutline,
              title: l10n.settingsDownloadDynamicFingerprint,
              subtitle: l10n.settingsDownloadDynamicFingerprintDesc,
              value: prefs.downloadDynamicFingerprint,
              onChanged: (v) {
                ref
                    .read(appPrefsProvider.notifier)
                    .setDownloadDynamicFingerprint(v);
                ref.read(downloadControllerProvider.notifier).syncSessions();
              },
            ),
            SettingTile(
              icon: EtaIcons.fingerprintOutline,
              title: l10n.settingsResetFingerprint,
              subtitle: l10n.settingsResetFingerprintDesc,
              trailing: IconButton(
                tooltip: l10n.settingsResetFingerprint,
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(EtaIcons.refreshOutline),
                onPressed: prefs.downloadDynamicFingerprint
                    ? null
                    : () => _resetFingerprint(context, l10n),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SettingNote(text: l10n.settingsGroupingNote),
      ],
    );
  }

  Future<void> _resetFingerprint(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    final ok = await SDialog.show<bool>(
      context,
      title: l10n.settingsResetFingerprint,
      description: l10n.settingsResetFingerprintDesc,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.settingsResetFingerprint,
          variant: SButtonVariant.error,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (ok != true || !mounted) return;
    ref
        .read(appPrefsProvider.notifier)
        .setDownloaderIdentity(jsonEncode(generateDownloaderIdentity()));
    ref.read(downloadControllerProvider.notifier).syncSessions();
    toast(l10n.toastFingerprintReset, type: ToastType.success);
  }

  void _saveDownloadRoot(String raw, AppLocalizations l10n) {
    final path = raw.trim();
    if (path.isEmpty) {
      toast(l10n.toastDownloadRootEmpty);
      return;
    }
    ref.read(appPrefsProvider.notifier).setDownload(rootDir: path);
    if (!mounted) return;
    toast(l10n.toastDownloadRootUpdated);
  }

  void _saveDownloadTemplate(String raw, AppLocalizations l10n) {
    final template = raw.trim();
    if (template.isEmpty) {
      toast(l10n.toastTemplateEmpty);
      return;
    }
    ref.read(appPrefsProvider.notifier).setDownload(filenameTemplate: template);
    if (!mounted) return;
    toast(l10n.toastTemplateUpdated);
  }

  String _fmtSpeedLabel(int bytesPerSec, AppLocalizations l10n) {
    if (bytesPerSec < 1024) return l10n.settingsSpeedBs(bytesPerSec);
    final kb = bytesPerSec / 1024;
    if (kb < 1024) return l10n.settingsSpeedKbs(kb.toStringAsFixed(0));
    return l10n.settingsSpeedMbs((kb / 1024).toStringAsFixed(1));
  }
}
