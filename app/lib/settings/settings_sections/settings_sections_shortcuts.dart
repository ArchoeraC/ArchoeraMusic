// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../settings_sections.dart';

/// 快捷键设置分区（独立分类页）：分组列出全部可绑定动作，支持逐项录制/
/// 清除/恢复默认与一键全部恢复。
class ShortcutsSection extends ConsumerWidget {
  const ShortcutsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final prefs = ref.watch(appPrefsProvider);
    final isMac = Theme.of(context).platform == TargetPlatform.macOS;

    // 生效绑定 → 占用动作（冲突提示用）。
    final used = <String, List<ShortcutAction>>{};
    for (final a in ShortcutAction.values) {
      final b = prefs.bindingFor(a);
      if (b.isEmpty) continue;
      used.putIfAbsent(b, () => []).add(a);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.shortcutNote,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 12),
            TextButton.icon(
              onPressed: prefs.shortcutOverrides.isEmpty
                  ? null
                  : () => ref
                        .read(appPrefsProvider.notifier)
                        .resetAllShortcuts(),
              icon: const Icon(EtaIcons.refresh, size: 16),
              label: Text(l10n.shortcutResetAll),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final cat in ShortcutCategory.values) ...[
          SettingSection(
            title: _categoryLabel(l10n, cat),
            children: [
              for (final action in ShortcutAction.values)
                if (action.category == cat)
                  _actionTile(context, ref, l10n, prefs, action, used, isMac),
            ],
          ),
          const SizedBox(height: 20),
        ],
      ],
    );
  }

  Widget _actionTile(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    AppPrefs prefs,
    ShortcutAction action,
    Map<String, List<ShortcutAction>> used,
    bool isMac,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final binding = prefs.bindingFor(action);
    final conflict = binding.isNotEmpty && (used[binding]?.length ?? 0) > 1;
    final display = binding.isEmpty
        ? l10n.shortcutUnbound
        : formatBinding(binding, isMac: isMac);
    return SettingTile(
      icon: action.icon,
      title: _actionLabel(l10n, action),
      subtitle: conflict ? l10n.shortcutConflict : l10n.shortcutHintEdit,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _capture(context, ref, l10n, action, used, isMac),
            child: Container(
              constraints: const BoxConstraints(minWidth: 64),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: (conflict ? scheme.error : scheme.outline)
                      .withValues(alpha: conflict ? 0.9 : 0.4),
                ),
              ),
              child: Text(
                display,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: binding.isEmpty
                      ? scheme.onSurfaceVariant.withValues(alpha: 0.7)
                      : scheme.onSurface,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: l10n.commonDefault,
            visualDensity: VisualDensity.compact,
            onPressed: prefs.shortcutOverride(action.id) == null
                ? null
                : () => ref
                      .read(appPrefsProvider.notifier)
                      .resetShortcut(action.id),
            icon: const Icon(EtaIcons.refreshOutline, size: 16),
          ),
        ],
      ),
    );
  }

  Future<void> _capture(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    ShortcutAction action,
    Map<String, List<ShortcutAction>> used,
    bool isMac,
  ) async {
    final others = <String>{
      for (final e in used.entries)
        if (e.value.any((a) => a.id != action.id)) e.key,
    };
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _ShortcutCaptureDialog(
        action: action,
        current: ref.read(appPrefsProvider).bindingFor(action),
        others: others,
        isMac: isMac,
      ),
    );
    if (result == null) return;
    ref.read(appPrefsProvider.notifier).setShortcut(action.id, result);
  }
}

/// 录制弹窗：捕获一次按键组合并返回绑定字符串（'' = 清除，null = 取消）。
class _ShortcutCaptureDialog extends StatefulWidget {
  const _ShortcutCaptureDialog({
    required this.action,
    required this.current,
    required this.others,
    required this.isMac,
  });

  final ShortcutAction action;
  final String current;
  final Set<String> others;
  final bool isMac;

  @override
  State<_ShortcutCaptureDialog> createState() => _ShortcutCaptureDialogState();
}

class _ShortcutCaptureDialogState extends State<_ShortcutCaptureDialog> {
  String? _captured;

  bool get _conflict =>
      _captured != null &&
      _captured!.isNotEmpty &&
      widget.others.contains(_captured);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    if (_isModifierKey(key)) return KeyEventResult.handled;
    final kb = HardwareKeyboard.instance;
    final activator = SingleActivator(
      key,
      control: kb.isControlPressed,
      alt: kb.isAltPressed,
      shift: kb.isShiftPressed,
      meta: kb.isMetaPressed,
    );
    final encoded = encodeBinding(activator);
    if (encoded == null) return KeyEventResult.handled;
    setState(() => _captured = encoded);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final preview = _captured == null || _captured!.isEmpty
        ? widget.current
        : _captured!;
    return SDialog(
      title: l10n.shortcutCaptureTitle,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _actionLabel(l10n, widget.action),
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          Focus(
            autofocus: true,
            onKeyEvent: _onKey,
            child: Container(
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(color: scheme.outline.withValues(alpha: 0.4)),
              ),
              child: Text(
                preview.isEmpty
                    ? l10n.shortcutPressKeys
                    : formatBinding(preview, isMac: widget.isMac),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: preview.isEmpty
                      ? scheme.onSurfaceVariant.withValues(alpha: 0.6)
                      : scheme.onSurface,
                ),
              ),
            ),
          ),
          if (_conflict) ...[
            const SizedBox(height: 10),
            Text(
              l10n.shortcutConflict,
              style: TextStyle(fontSize: 12, color: scheme.error),
            ),
          ],
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(''),
                child: Text(l10n.commonClear),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.commonCancel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _captured == null || _captured!.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(_captured),
                child: Text(l10n.commonSave),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

bool _isModifierKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.control ||
    key == LogicalKeyboardKey.controlLeft ||
    key == LogicalKeyboardKey.controlRight ||
    key == LogicalKeyboardKey.alt ||
    key == LogicalKeyboardKey.altLeft ||
    key == LogicalKeyboardKey.altRight ||
    key == LogicalKeyboardKey.shift ||
    key == LogicalKeyboardKey.shiftLeft ||
    key == LogicalKeyboardKey.shiftRight ||
    key == LogicalKeyboardKey.meta ||
    key == LogicalKeyboardKey.metaLeft ||
    key == LogicalKeyboardKey.metaRight;

String _categoryLabel(AppLocalizations l10n, ShortcutCategory cat) =>
    switch (cat) {
      ShortcutCategory.playback => l10n.shortcutCategoryPlayback,
      ShortcutCategory.seek => l10n.shortcutCategorySeek,
      ShortcutCategory.volume => l10n.shortcutCategoryVolume,
      ShortcutCategory.queue => l10n.shortcutCategoryQueue,
      ShortcutCategory.navigation => l10n.shortcutCategoryNavigation,
    };

String _actionLabel(AppLocalizations l10n, ShortcutAction a) => switch (a) {
  ShortcutAction.playPause => l10n.shortcutActionPlayPause,
  ShortcutAction.play => l10n.shortcutActionPlay,
  ShortcutAction.pause => l10n.shortcutActionPause,
  ShortcutAction.stop => l10n.shortcutActionStop,
  ShortcutAction.next => l10n.shortcutActionNext,
  ShortcutAction.previous => l10n.shortcutActionPrevious,
  ShortcutAction.likeToggle => l10n.shortcutActionLikeToggle,
  ShortcutAction.shuffleToggle => l10n.shortcutActionShuffleToggle,
  ShortcutAction.repeatCycle => l10n.shortcutActionRepeatCycle,
  ShortcutAction.reload => l10n.shortcutActionReload,
  ShortcutAction.seekBackward => l10n.shortcutActionSeekBackward,
  ShortcutAction.seekForward => l10n.shortcutActionSeekForward,
  ShortcutAction.seekBackwardLong => l10n.shortcutActionSeekBackwardLong,
  ShortcutAction.seekForwardLong => l10n.shortcutActionSeekForwardLong,
  ShortcutAction.volumeUp => l10n.shortcutActionVolumeUp,
  ShortcutAction.volumeDown => l10n.shortcutActionVolumeDown,
  ShortcutAction.muteToggle => l10n.shortcutActionMuteToggle,
  ShortcutAction.jumpToFirst => l10n.shortcutActionJumpToFirst,
  ShortcutAction.jumpToLast => l10n.shortcutActionJumpToLast,
  ShortcutAction.clearQueue => l10n.shortcutActionClearQueue,
  ShortcutAction.goHome => l10n.shortcutActionGoHome,
  ShortcutAction.goLibrary => l10n.shortcutActionGoLibrary,
  ShortcutAction.goSearch => l10n.shortcutActionGoSearch,
  ShortcutAction.goLiked => l10n.shortcutActionGoLiked,
  ShortcutAction.goFavorites => l10n.shortcutActionGoFavorites,
  ShortcutAction.goHistory => l10n.shortcutActionGoHistory,
  ShortcutAction.goDownload => l10n.shortcutActionGoDownload,
  ShortcutAction.goStreaming => l10n.shortcutActionGoStreaming,
  ShortcutAction.openPlayer => l10n.shortcutActionOpenPlayer,
  ShortcutAction.openSettings => l10n.shortcutActionOpenSettings,
  ShortcutAction.back => l10n.shortcutActionBack,
};
