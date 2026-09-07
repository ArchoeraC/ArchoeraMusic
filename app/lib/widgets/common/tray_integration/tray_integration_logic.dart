// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../tray_integration.dart';

extension _TrayIntegrationLogic on _TrayIntegrationState {
  Future<void> _setup() async {
    try {
      await _initTray();
      windowManager.addListener(this);
      await windowManager.setPreventClose(true);
      _trayReady = true;
    } catch (e) {
      debugPrint('[tray] 初始化失败，降级为正常关闭退出: $e');
      _trayReady = false;
      try {
        await trayManager.destroy();
      } catch (_) {}
    }
  }

  Future<void> _initTray() async {
    trayManager.addListener(this);
    final iconAsset = Platform.isWindows
        ? 'assets/icons/tray.ico'
        : 'assets/icons/tray.png';
    await trayManager.setIcon(iconAsset);
    try {
      await trayManager.setToolTip('ArchoeraMusic');
    } catch (_) {}
    await trayManager.setContextMenu(_buildMenu());
  }

  Menu _buildMenu() {
    final l10n = ref.read(l10nProvider);
    return Menu(
      items: [
        MenuItem(
          key: 'show',
          label: l10n.trayShow,
          onClick: (_) => _showWindow(),
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'toggle',
          label: l10n.trayPlayPause,
          onClick: (_) => ref.read(playbackProvider.notifier).toggle(),
        ),
        MenuItem(
          key: 'prev',
          label: l10n.trayPrevious,
          onClick: (_) {
            unawaited(ref.read(playbackProvider.notifier).playPrevious());
          },
        ),
        MenuItem(
          key: 'next',
          label: l10n.trayNext,
          onClick: (_) {
            unawaited(ref.read(playbackProvider.notifier).playNext());
          },
        ),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: l10n.trayQuit, onClick: (_) => _quit()),
      ],
    );
  }

  Future<void> _rebuildMenu() async {
    if (!_trayReady) return;
    await trayManager.setContextMenu(_buildMenu());
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    await quitApplication(ref);
  }

  Future<void> _handleWindowClose() async {
    final behavior = ref.read(appPrefsProvider).closeBehavior;
    switch (behavior) {
      case 'quit':
        await _quit();
      case 'background':
        await windowManager.hide();
      default:
        await _askCloseBehavior();
    }
  }

  Future<void> _askCloseBehavior() async {
    _closeRemember = false;
    final notifier = ref.read(playbackProvider.notifier);
    await notifier.duckVolume();
    try {
      final nav = rootNavigatorKey.currentContext;
      if (nav == null) return;
      final l10n = ref.read(l10nProvider);
      if (!nav.mounted) return;
      final choice = await SDialog.show<(String, bool)>(
        nav,
        title: l10n.commonCloseConfirmTitle,
        description: l10n.commonCloseConfirmMessage,
        child: StatefulBuilder(
          builder: (dialogContext, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _closeOption(
                dialogContext,
                l10n.settingsCloseBehaviorBackground,
                EtaIcons.headphoneOutline,
                'background',
              ),
              const SizedBox(height: 8),
              _closeOption(
                dialogContext,
                l10n.settingsCloseBehaviorQuit,
                EtaIcons.powerOutline,
                'quit',
              ),
              const SizedBox(height: 12),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () =>
                    setDialogState(() => _closeRemember = !_closeRemember),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 2,
                  ),
                  child: Row(
                    children: [
                      Checkbox(
                        value: _closeRemember,
                        onChanged: (v) =>
                            setDialogState(() => _closeRemember = v ?? false),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          l10n.commonCloseConfirmRemember,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: Theme.of(
                              dialogContext,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      if (choice == null) return;
      final (behavior, remember) = choice;
      if (remember) {
        ref.read(appPrefsProvider.notifier).setCloseBehavior(behavior);
      }
      if (behavior == 'quit') {
        await _quit();
      } else {
        await windowManager.hide();
      }
    } finally {
      await notifier.restoreVolume();
    }
  }

  Widget _closeOption(
    BuildContext dialogContext,
    String label,
    IconData icon,
    String value,
  ) {
    final scheme = Theme.of(dialogContext).colorScheme;
    return Material(
      color: scheme.onSurface.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => Navigator.of(dialogContext).pop((value, _closeRemember)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              Icon(
                EtaIcons.rightSmall,
                size: 18,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _handleTrayIconMouseDown() {
    unawaited(_showWindow());
  }

  void _handleTrayIconRightMouseDown() {
    if (Platform.isWindows) {
      unawaited(trayManager.popUpContextMenu());
    }
  }

  Widget _buildTrayIntegration(BuildContext context) {
    ref.listen(localeProvider, (prev, next) {
      if (prev != next) unawaited(_rebuildMenu());
    });
    return widget.child;
  }
}
