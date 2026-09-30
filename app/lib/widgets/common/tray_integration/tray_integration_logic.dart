// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../tray_integration.dart';

extension _TrayIntegrationLogic on _TrayIntegrationState {
  Future<void> _setup() async {
    try {
      _initTray();
      windowManager.addListener(this);
      await windowManager.setPreventClose(true);
      _trayReady = true;
    } catch (e) {
      Log.w('tray', '初始化失败，降级为正常关闭退出: $e');
      _trayReady = false;
      _disposeTray();
    }
  }

  void _initTray() {
    final trayIcon = TrayIcon.create();
    if (trayIcon == null) {
      throw StateError('无法创建系统托盘图标');
    }
    _trayIcon = trayIcon;

    final iconAsset = Platform.isWindows
        ? 'assets/icons/tray.ico'
        : 'assets/icons/tray.png';
    final icon = ImageAsset.fromAsset(iconAsset);
    if (icon == null) {
      throw ArgumentError.value(iconAsset, 'iconAsset', '无法加载托盘图标资源');
    }
    trayIcon.icon = icon;
    trayIcon.setTooltip('ArchoeraMusic');
    // 菜单唤出方式：
    // - Linux 的 StatusNotifierItem 只有 Trigger=clicked 时才会把菜单暴露给面板
    //   （面板自行打开菜单，托盘点击事件不上报）；
    // - Windows / macOS 用右键唤出菜单，左键留给「显示主窗口」。
    trayIcon.setContextMenuTrigger(
      Platform.isLinux
          ? ContextMenuTrigger.clicked
          : ContextMenuTrigger.rightClicked,
    );
    trayIcon.addListener(_onTrayIconEvent);
    _trayMenu = _buildMenu();
    trayIcon.setContextMenu(_trayMenu);
    trayIcon.setVisible(true);
  }

  void _onTrayIconEvent(TrayIconEvent event) {
    switch (event) {
      case TrayIconClickedEvent():
        unawaited(_showWindow());
      case TrayIconDoubleClickedEvent():
        unawaited(_showWindow());
      case TrayIconRightClickedEvent():
        // Windows / macOS 已由 contextMenuTrigger 自动弹出菜单，无需手动处理。
        break;
    }
  }

  Menu _buildMenu() {
    final l10n = ref.read(l10nProvider);
    final menu = Menu.create();
    if (menu == null) {
      throw StateError('无法创建托盘菜单');
    }
    _trayMenuItems.clear();

    _addMenuItem(menu, l10n.trayShow, () => unawaited(_showWindow()));
    menu.addSeparator();
    _addMenuItem(
      menu,
      l10n.trayPlayPause,
      () => ref.read(playbackProvider.notifier).toggle(),
    );
    _addMenuItem(
      menu,
      l10n.trayPrevious,
      () => unawaited(ref.read(playbackProvider.notifier).playPrevious()),
    );
    _addMenuItem(
      menu,
      l10n.trayNext,
      () => unawaited(ref.read(playbackProvider.notifier).playNext()),
    );
    menu.addSeparator();
    _addMenuItem(menu, l10n.trayQuit, () => unawaited(_quit()));
    return menu;
  }

  void _addMenuItem(Menu menu, String label, void Function() onTap) {
    final item = MenuItem.createWithLabelAndType(label, MenuItemType.normal);
    if (item == null) return;
    item.addListener((event) {
      if (event is MenuItemClickedEvent) onTap();
    });
    menu.addItem(item);
    _trayMenuItems.add(item);
  }

  void _rebuildMenu() {
    if (!_trayReady) return;
    final trayIcon = _trayIcon;
    if (trayIcon == null) return;

    final previousItems = List<MenuItem>.of(_trayMenuItems);
    final previousMenu = _trayMenu;
    final menu = _buildMenu();
    trayIcon.setContextMenu(menu);
    _trayMenu = menu;
    // 旧菜单已从托盘解绑：释放其菜单项监听与句柄（原生侧仍持共享引用，安全）。
    for (final item in previousItems) {
      item.dispose();
    }
    previousMenu?.dispose();
  }

  void _disposeTray() {
    for (final item in _trayMenuItems) {
      item.dispose();
    }
    _trayMenuItems.clear();
    _trayMenu?.dispose();
    _trayMenu = null;
    _trayIcon?.dispose();
    _trayIcon = null;
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
