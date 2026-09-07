// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../services/scanner/library_scanner.dart';
import '../../stores/app_prefs.dart';
import 'settings_widgets.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

/// 扫描分类：并行度 / 批大小 / 安全上限 / 额外扩展名 / 坏文件隔离管理。
///
/// 扫描触发（增量/全量）在音乐库页（更多菜单 → 全量扫描）；本分类只配置
/// 引擎参数与维护隔离区。数值 0 = 引擎默认（自适应或内置安全值）。
class ScansSection extends ConsumerStatefulWidget {
  const ScansSection({super.key});

  @override
  ConsumerState<ScansSection> createState() => _ScansSectionState();
}

class _ScansSectionState extends ConsumerState<ScansSection> {
  late final TextEditingController _maxFileSizeCtrl;
  late final TextEditingController _maxScanFilesCtrl;
  late final TextEditingController _maxErrorsCtrl;
  late final TextEditingController _extraExtsCtrl;

  /// 隔离目录文件列表（名称/大小/修改时间）。
  List<File> _quarantined = const [];
  bool _loadingQuarantine = false;

  @override
  void initState() {
    super.initState();
    final p = ref.read(appPrefsProvider);
    _maxFileSizeCtrl = TextEditingController(
      text: p.scanMaxFileSizeMb > 0 ? '${p.scanMaxFileSizeMb}' : '',
    );
    _maxScanFilesCtrl = TextEditingController(
      text: p.scanMaxScanFiles > 0 ? '${p.scanMaxScanFiles}' : '',
    );
    _maxErrorsCtrl = TextEditingController(
      text: p.scanMaxScanErrors > 0 ? '${p.scanMaxScanErrors}' : '',
    );
    _extraExtsCtrl = TextEditingController(
      text: p.scanExtraExts.join(' '),
    );
    _refreshQuarantine();
  }

  @override
  void dispose() {
    _maxFileSizeCtrl.dispose();
    _maxScanFilesCtrl.dispose();
    _maxErrorsCtrl.dispose();
    _extraExtsCtrl.dispose();
    super.dispose();
  }

  String get _quarantineDir => '${LibraryScanner.defaultDataDir()}/database/quarantine';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final prefs = ref.watch(appPrefsProvider);
    final notifier = ref.read(appPrefsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsSectionScanRun,
          children: [
            SettingSliderTile(
              icon: EtaIcons.dashboard4Outline,
              title: l10n.settingsScanParallelism,
              subtitle: l10n.settingsScanParallelismDesc(
                prefs.scanParallelism <= 0
                    ? l10n.settingsValueAuto
                    : '${prefs.scanParallelism}',
              ),
              value: prefs.scanParallelism.toDouble().clamp(0, 64),
              min: 0,
              max: 64,
              divisions: 64,
              onChanged: (v) =>
                  notifier.setScan(parallelism: v.round()),
            ),
            SettingSliderTile(
              icon: EtaIcons.menuOutline,
              title: l10n.settingsScanBatch,
              subtitle: l10n.settingsScanBatchDesc(
                prefs.scanBatchSize <= 0
                    ? l10n.settingsValueAuto
                    : '${prefs.scanBatchSize}',
              ),
              value: prefs.scanBatchSize.toDouble().clamp(0, 400),
              min: 0,
              max: 400,
              divisions: 40,
              onChanged: (v) => notifier.setScan(batchSize: v.round()),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionScanLimits,
          note: l10n.settingsScanLimitsNote,
          children: [
            _numberTile(
              scheme,
              l10n,
              EtaIcons.storageOutline,
              l10n.settingsScanMaxFileSizeMb,
              _maxFileSizeCtrl,
              onCommit: (v) => notifier.setScan(maxFileSizeMb: v),
            ),
            _numberTile(
              scheme,
              l10n,
              EtaIcons.hashtagOutline,
              l10n.settingsScanMaxScanFiles,
              _maxScanFilesCtrl,
              onCommit: (v) => notifier.setScan(maxScanFiles: v),
            ),
            _numberTile(
              scheme,
              l10n,
              EtaIcons.alertOutline,
              l10n.settingsScanMaxErrors,
              _maxErrorsCtrl,
              onCommit: (v) => notifier.setScan(maxScanErrors: v),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionScanExts,
          note: l10n.settingsScanExtraExtsNote,
          children: [
            SettingPathFieldCard(
              icon: EtaIcons.pluginOutline,
              ctrl: _extraExtsCtrl,
              hint: l10n.settingsScanExtraExtsHint,
              save: (v) {
                final exts = v
                    .split(RegExp(r'[\s,;]+'))
                    .map((e) => e.trim().replaceFirst('.', '').toLowerCase())
                    .where((e) => e.isNotEmpty)
                    .toSet()
                    .toList();
                notifier.setScan(extraExts: exts);
              },
              restoreDefault: () => '',
            ),
          ],
        ),
        const SizedBox(height: 20),
        SettingSection(
          title: l10n.settingsSectionScanQuarantine,
          note: l10n.settingsScanQuarantineNote(_quarantineDir),
          children: [
            if (_loadingQuarantine)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: LinearProgressIndicator(minHeight: 3),
              )
            else if (_quarantined.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Text(
                  l10n.settingsScanQuarantineEmpty,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final f in _quarantined)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            const Icon(EtaIcons.fileOutline,
                                size: 15),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                f.uri.pathSegments.isNotEmpty
                                    ? f.uri.pathSegments.last
                                    : f.path,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12.5),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _fmtSize(f.lengthSync()),
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            IconButton(
                              iconSize: 16,
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(EtaIcons.deleteOutline),
                              tooltip: l10n.settingsScanQuarantineDelete,
                              onPressed: () => _deleteQuarantined(f),
                            ),
                          ],
                        ),
                      ),
                    const Divider(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          const Spacer(),
                          SizedBox(
                            height: 28,
                            child: TextButton.icon(
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              onPressed: _openQuarantineDir,
                              icon: const Icon(EtaIcons.folderOpen, size: 15),
                              label: Text(
                                l10n.settingsScanQuarantineOpenDir,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ),
                          SizedBox(
                            height: 28,
                            child: TextButton.icon(
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              onPressed: _clearQuarantine,
                              icon: const Icon(EtaIcons.wastebasketOutline,
                                  size: 15),
                              label: Text(
                                l10n.settingsScanQuarantineClearAll,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  /// 数值设置行：图标徽章 + 标题 + 右侧数字输入框（空 = 引擎默认）。
  Widget _numberTile(
    ColorScheme scheme,
    AppLocalizations l10n,
    IconData icon,
    String title,
    TextEditingController ctrl, {
    required ValueChanged<int> onCommit,
  }) {
    return SettingTile(
      icon: icon,
      title: title,
      subtitle: l10n.settingsScanNumberDesc,
      trailing: SizedBox(
        width: 118,
        child: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.right,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(isDense: true, border: InputBorder.none),
          onSubmitted: (v) {
            final n = int.tryParse(v.trim()) ?? 0;
            onCommit(n.clamp(0, 2147483647));
          },
        ),
      ),
    );
  }

  // ── 隔离区管理（纯 Dart：列表目录 + 删除/清空 + 打开目录）──

  Future<void> _refreshQuarantine() async {
    _loadingQuarantine = true;
    try {
      final raw = await Future(() {
        try {
          final dir = Directory(_quarantineDir);
          if (!dir.existsSync()) return const <File>[];
          return dir
              .listSync()
              .whereType<File>()
              .where((f) => f.existsSync())
              .toList();
        } catch (_) {
          return const <File>[];
        }
      });
      // const <File>[] 不可变：sort 前统一转可变副本，避免 Unsupported operation
      final list = raw.toList()..sort((a, b) => b.path.compareTo(a.path));
      if (!mounted) return;
      setState(() {
        _quarantined = list;
      });
    } catch (_) {
      // 目录枚举/排序异常不阻断页面：保持空列表可交互
      if (!mounted) return;
      setState(() {
        _quarantined = const [];
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingQuarantine = false;
        });
      }
    }
  }

  Future<void> _deleteQuarantined(File f) async {
    try {
      f.deleteSync();
    } catch (_) {}
    await _refreshQuarantine();
  }

  Future<void> _clearQuarantine() async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.settingsScanQuarantineClearAll),
        content: Text(l10n.settingsScanQuarantineClearAllConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    for (final f in _quarantined) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
    await _refreshQuarantine();
  }

  void _openQuarantineDir() {
    try {
      Process.start('xdg-open', [_quarantineDir]);
    } catch (_) {
      // 无 xdg-open（macOS/Windows）忽略；隔离目录路径已在 note 中展示
    }
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }
}
