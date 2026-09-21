// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 睡眠定时相关弹窗：自定义分钟数、编辑快捷预设。
///
/// 时长统一 clamp 到 `[minSleepTimerMinutes, maxSleepTimerMinutes]`（1~600）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../eta/icon/eta_icons.dart';
import '../../l10n/l10n.dart';
import '../../stores/prefs_player.dart';
import 's_dialog.dart';

/// 自定义睡眠定时：输入分钟数，确认返回分钟数，取消返回 null。
Future<int?> showSleepTimerMinutesDialog(
  BuildContext context, {
  int initialMinutes = 30,
}) {
  final initial = initialMinutes.clamp(
    minSleepTimerMinutes,
    maxSleepTimerMinutes,
  );
  return showDialog<int>(
    context: context,
    useRootNavigator: false,
    builder: (_) => _SleepTimerMinutesDialog(initialMinutes: initial),
  );
}

class _SleepTimerMinutesDialog extends StatefulWidget {
  const _SleepTimerMinutesDialog({required this.initialMinutes});

  final int initialMinutes;

  @override
  State<_SleepTimerMinutesDialog> createState() =>
      _SleepTimerMinutesDialogState();
}

class _SleepTimerMinutesDialogState extends State<_SleepTimerMinutesDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.initialMinutes}');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = context.l10n;
    final v = int.tryParse(_controller.text.trim());
    if (v == null || v < minSleepTimerMinutes || v > maxSleepTimerMinutes) {
      setState(() => _error = l10n.sleepTimerCustomInvalid);
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SDialog(
      title: l10n.sleepTimerCustomTitle,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.commonConfirm)),
      ],
      child: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: l10n.sleepTimerCustomLabel,
          suffixText: l10n.sleepTimerMinutesUnit,
          errorText: _error,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

/// 编辑睡眠定时快捷预设：返回编辑后的分钟数列表（可空列表 = 删光），取消返回 null。
Future<List<int>?> showSleepTimerPresetsDialog(
  BuildContext context,
  List<int> presets,
) {
  return showDialog<List<int>>(
    context: context,
    useRootNavigator: false,
    builder: (_) => _SleepTimerPresetsDialog(presets: presets),
  );
}

class _SleepTimerPresetsDialog extends StatefulWidget {
  const _SleepTimerPresetsDialog({required this.presets});

  final List<int> presets;

  @override
  State<_SleepTimerPresetsDialog> createState() =>
      _SleepTimerPresetsDialogState();
}

class _SleepTimerPresetsDialogState extends State<_SleepTimerPresetsDialog> {
  late List<int> _presets;
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _presets = List.of(widget.presets);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add() {
    final l10n = context.l10n;
    final v = int.tryParse(_controller.text.trim());
    if (v == null || v < minSleepTimerMinutes || v > maxSleepTimerMinutes) {
      setState(() => _error = l10n.sleepTimerCustomInvalid);
      return;
    }
    if (_presets.contains(v)) {
      setState(() => _error = l10n.sleepTimerPresetsDuplicate);
      return;
    }
    setState(() {
      _presets = [..._presets, v]..sort();
      _error = null;
      _controller.clear();
    });
  }

  void _remove(int minutes) {
    setState(() => _presets = _presets.where((e) => e != minutes).toList());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return SDialog(
      title: l10n.sleepTimerPresets,
      description: l10n.sleepTimerPresetsDesc,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_presets),
          child: Text(l10n.commonConfirm),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _add(),
                  decoration: InputDecoration(
                    labelText: l10n.sleepTimerCustomLabel,
                    suffixText: l10n.sleepTimerMinutesUnit,
                    errorText: _error,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.tonal(
                onPressed: _add,
                child: Text(l10n.sleepTimerPresetsAdd),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_presets.isEmpty)
            Text(
              l10n.sleepTimerPresetsEmpty,
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in _presets)
                  InputChip(
                    label: Text(l10n.sleepTimerMinutes(minutes: m)),
                    deleteIcon: const Icon(EtaIcons.deleteOutline, size: 18),
                    onDeleted: () => _remove(m),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
