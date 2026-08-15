import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../services/history/history_store.dart';
import '../../stores/app_prefs.dart';
import '../../widgets/common/toast.dart';
import '../../widgets/dialogs/s_dialog.dart';
import '../../widgets/player/s_controls.dart';
import 'settings_widgets.dart';

/// 播放历史条数上限滑块的取值范围与步长（100 ~ 5000，每档 100）。
const int historyLimitMin = 100;
const int historyLimitMax = 5000;
const int historyLimitStep = 100;

/// 存储分类下的「播放历史」管理面板。
///
/// 数据为独立库 history.db（与曲库 library.db 分库），此处提供 UI 管理：
/// - 记录开关（关闭 = 暂停记录，已有数据保留，历史页仍可查看）；
/// - 条数上限（null = 不限制，需弹窗确认存储占用与卡顿风险）；
/// - 当前条数 + 库文件大小 + 清空（二次确认）。
class HistorySection extends ConsumerStatefulWidget {
  const HistorySection({super.key});

  @override
  ConsumerState<HistorySection> createState() => _HistorySectionState();
}

class _HistorySectionState extends ConsumerState<HistorySection> {
  int _count = 0;
  int _bytes = 0;

  /// 历史变更订阅（记录 / 清空 / 裁剪后即时刷新统计，事件驱动）。
  StreamSubscription<HistoryChangedEvent>? _changesSub;

  @override
  void initState() {
    super.initState();
    _changesSub = HistoryStore.changes
        .on<HistoryChangedEvent>()
        .listen((_) => _refresh());
    _refresh();
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    super.dispose();
  }

  /// 重算统计（条数同步读 SQLite；库小、WAL 直读微秒级，不阻塞 UI）。
  void _refresh() {
    final file = File(HistoryStore.defaultDbPath());
    if (!mounted) return;
    setState(() {
      _bytes = file.existsSync() ? file.lengthSync() : 0;
      _count = HistoryStore.shared.count();
    });
  }

  /// 上限开关：开启 → 恢复限额（当前值或默认 500）；关闭（= 不限制）→
  /// 弹窗警告存储占用与卡顿风险，确认后才真正写入（用户明确知情）。
  Future<void> _onLimitToggle(
    BuildContext context, {
    required bool enabled,
    required VoidCallback onEnable,
    required VoidCallback onDisable,
  }) async {
    if (enabled) {
      onEnable();
      return;
    }
    final l10n = context.l10n;
    final ok = await SDialog.show<bool>(
      context,
      title: l10n.settingsHistoryNoLimitConfirmTitle,
      description: l10n.settingsHistoryNoLimitConfirmDesc,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.settingsHistoryNoLimitConfirm,
          variant: SButtonVariant.error,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (ok == true) onDisable();
  }

  /// 清空全部历史（确认弹窗，复用历史页文案）。
  Future<void> _clear() async {
    final l10n = context.l10n;
    final ok = await SDialog.show<bool>(
      context,
      title: l10n.pageHistoryClearTitle,
      description: l10n.pageHistoryClearMessage,
      child: const SizedBox.shrink(),
      actions: [
        SButton(
          label: l10n.commonCancel,
          variant: SButtonVariant.secondary,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        SButton(
          label: l10n.commonClear,
          variant: SButtonVariant.error,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    if (ok != true) return;
    HistoryStore.shared.clear();
    _refresh();
    if (context.mounted) {
      toast(l10n.pageHistoryCleared, type: ToastType.success);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final prefs = ref.watch(appPrefsProvider);
    final notifier = ref.read(appPrefsProvider.notifier);
    final limit = prefs.historyLimit; // null = 不限制
    final enabled = prefs.historyEnabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingSection(
          title: l10n.settingsHistorySection,
          note: l10n.settingsHistoryNote,
          children: [
            // 记录开关
            SettingSwitchTile(
              icon: enabled ? Icons.history : Icons.history_outlined,
              title: l10n.settingsHistoryEnabled,
              subtitle: enabled
                  ? l10n.settingsHistoryEnabledOn
                  : l10n.settingsHistoryEnabledOff,
              value: enabled,
              onChanged: notifier.setHistoryEnabled,
            ),
            if (enabled) ...[
              // 条数上限开关（关闭 = 不限制，弹窗确认）
              SettingSwitchTile(
                icon: Icons.tune,
                title: l10n.settingsHistoryLimit,
                subtitle: limit == null
                    ? l10n.settingsHistoryLimitUnlimited
                    : l10n.settingsHistoryLimitOn(limit),
                value: limit != null,
                onChanged: (v) => _onLimitToggle(
                  context,
                  enabled: v,
                  onEnable: () {
                    final cur = limit ?? HistoryStore.defaultLimit;
                    notifier.setHistoryLimit(cur);
                    HistoryStore.shared.trim(cur);
                  },
                  onDisable: () => notifier.setHistoryLimit(null),
                ),
              ),
              if (limit != null)
                SettingSliderTile(
                  icon: Icons.storage_outlined,
                  title: l10n.settingsHistoryLimit,
                  subtitle: l10n.settingsHistoryLimitOn(limit),
                  value: limit.toDouble().clamp(
                    historyLimitMin.toDouble(),
                    historyLimitMax.toDouble(),
                  ),
                  min: historyLimitMin.toDouble(),
                  max: historyLimitMax.toDouble(),
                  divisions:
                      (historyLimitMax - historyLimitMin) ~/ historyLimitStep,
                  label: l10n.settingsHistoryLimitOn(limit),
                  onChanged: (v) {
                    final rounded =
                        ((v.round() ~/ historyLimitStep) * historyLimitStep);
                    notifier.setHistoryLimit(rounded);
                  },
                  onChangeEnd: (v) {
                    final rounded =
                        ((v.round() ~/ historyLimitStep) * historyLimitStep);
                    HistoryStore.shared.trim(rounded);
                  },
                ),
              // 统计 + 清空
              SettingTile(
                icon: Icons.cleaning_services_outlined,
                title: l10n.settingsHistoryStats,
                subtitle:
                    '${l10n.settingsCacheEntries(_count)} · ${_formatBytes(_bytes)}',
                trailing: IconButton(
                  tooltip: l10n.commonClear,
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  onPressed: _count > 0 ? _clear : null,
                  icon: Icon(
                    Icons.delete_outline,
                    color: _count > 0
                        ? scheme.error
                        : scheme.onSurface.withValues(alpha: 0.25),
                  ),
                ),
              ),
            ],
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
