// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../tray_integration.dart';

/// 托盘菜单项 id（>0 可点击；0 为分隔符）。
const int _menuShow = 1;
const int _menuPlayPause = 2;
const int _menuPrevious = 3;
const int _menuNext = 4;
const int _menuQuit = 5;

extension _TrayIntegrationLogic on _TrayIntegrationState {
  Future<void> _setup() async {
    try {
      await _initTray();
      windowManager.addListener(this);
      await windowManager.setPreventClose(true);
      _trayReady = true;
    } catch (e) {
      Log.w('tray', '初始化失败，降级为正常关闭退出: $e');
      _trayReady = false;
      _disposeTray();
    }
  }

  Future<void> _initTray() async {
    final tray = ref.read(platformCapabilitiesProvider).tray;
    _tray = tray;

    // 图标资源 → 临时文件（桥接按文件路径加载；Windows 用 .ico）。
    final iconAsset = Platform.isWindows
        ? 'assets/icons/tray.ico'
        : 'assets/icons/tray.png';
    final ext = Platform.isWindows ? 'ico' : 'png';
    final data = await rootBundle.load(iconAsset);
    final path =
        '${Directory.systemTemp.path}/archoera-tray-$pid-'
        '${DateTime.now().microsecondsSinceEpoch}.$ext';
    await File(path).writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    _iconTempPath = path;

    if (tray.create(path) != 0) {
      throw StateError('无法创建系统托盘图标');
    }
    tray.setTooltip('ArchoeraMusic');
    // 菜单唤出方式：Linux 的 StatusNotifierItem 由面板在左键时展开菜单；
    // Windows / macOS 用右键唤出，左键留给「显示主窗口」。
    tray.setMenuTrigger(Platform.isLinux);
    _traySubs.add(tray.clicks.listen((_) => unawaited(_showWindow())));
    _traySubs.add(tray.doubleClicks.listen((_) => unawaited(_showWindow())));
    _traySubs.add(tray.menuCommands.listen(_onMenuCommand));
    _trayFailures = tray.failures.listen((f) => Log.w('tray', f.toString()));
    tray.setMenu(_buildMenuItems());
    tray.setVisible(true);
  }

  void _onMenuCommand(int id) {
    switch (id) {
      case _menuShow:
        unawaited(_showWindow());
      case _menuPlayPause:
        ref.read(playbackProvider.notifier).toggle();
      case _menuPrevious:
        unawaited(ref.read(playbackProvider.notifier).playPrevious());
      case _menuNext:
        unawaited(ref.read(playbackProvider.notifier).playNext());
      case _menuQuit:
        unawaited(_quit());
    }
  }

  List<SystemTrayMenuItem> _buildMenuItems() {
    final l10n = ref.read(l10nProvider);
    return <SystemTrayMenuItem>[
      SystemTrayMenuItem(id: _menuShow, label: l10n.trayShow),
      const SystemTrayMenuItem(id: 0),
      SystemTrayMenuItem(id: _menuPlayPause, label: l10n.trayPlayPause),
      SystemTrayMenuItem(id: _menuPrevious, label: l10n.trayPrevious),
      SystemTrayMenuItem(id: _menuNext, label: l10n.trayNext),
      const SystemTrayMenuItem(id: 0),
      SystemTrayMenuItem(id: _menuQuit, label: l10n.trayQuit),
    ];
  }

  void _rebuildMenu() {
    if (!_trayReady) return;
    _tray?.setMenu(_buildMenuItems());
  }

  void _disposeTray() {
    for (final s in _traySubs) {
      unawaited(s.cancel());
    }
    _traySubs.clear();
    unawaited(_trayFailures?.cancel());
    _trayFailures = null;
    _tray?.destroy();
    _tray = null;
    final path = _iconTempPath;
    if (path != null) {
      try {
        File(path).deleteSync();
      } catch (_) {
        // 临时文件清理失败可忽略。
      }
      _iconTempPath = null;
    }
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

  Widget _buildTrayIntegration(BuildContext context) {
    ref.listen(localeProvider, (prev, next) {
      if (prev != next) _rebuildMenu();
    });
    return widget.child;
  }
}
