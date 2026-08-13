import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/playback/playback_notifier.dart';
import '../../stores/app_prefs.dart';
import '../../l10n/l10n.dart';
import '../../app/app_quit.dart';
import '../../app/router.dart';
import '../dialogs/s_dialog.dart';

/// 后台常驻：系统托盘集成。
///
/// 关闭窗口按「关闭应用时」偏好处理（后台播放 / 直接退出；默认每次询问，
/// 弹确认框含记忆勾选）。托盘菜单：显示主窗口 / 播放暂停 / 上一首 / 下一首 /
/// 退出。托盘初始化失败时降级为正常关闭退出。
class TrayIntegration extends ConsumerStatefulWidget {
  const TrayIntegration({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TrayIntegration> createState() => _TrayIntegrationState();
}

class _TrayIntegrationState extends ConsumerState<TrayIntegration>
    with WindowListener, TrayListener {
  /// 托盘是否就绪（决定关闭窗口是否隐藏到托盘）。
  bool _trayReady = false;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    try {
      // 先建托盘：托盘就绪才拦截窗口关闭（避免托盘失败时窗口关不掉）
      await _initTray();
      windowManager.addListener(this);
      await windowManager.setPreventClose(true);
      _trayReady = true;
    } catch (e) {
      // 桌面环境无托盘支持等场景：降级为正常关闭退出，不阻塞应用
      debugPrint('[tray] 初始化失败，降级为正常关闭退出: $e');
      _trayReady = false;
      try {
        await trayManager.destroy();
      } catch (_) {}
    }
  }

  Future<void> _initTray() async {
    trayManager.addListener(this);
    // iconPath 为 pubspec 注册的资产路径（Linux 侧按 bundle flutter_assets 解析）
    await trayManager.setIcon('assets/icons/tray.png');
    // setToolTip 在部分桌面插件实现中缺失（Linux 未实现），失败不影响核心功能
    try {
      await trayManager.setToolTip('ArchoeraMusic');
    } catch (_) {}
    await trayManager.setContextMenu(_buildMenu());
  }

  /// 托盘菜单（文案跟随当前界面语言）。
  Menu _buildMenu() {
    final l10n = ref.read(l10nProvider);
    return Menu(items: [
      MenuItem(key: 'show', label: l10n.trayShow, onClick: (_) => _showWindow()),
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
          // ignore: discarded_futures
          unawaited(ref.read(playbackProvider.notifier).playPrevious());
        },
      ),
      MenuItem(
        key: 'next',
        label: l10n.trayNext,
        onClick: (_) {
          // ignore: discarded_futures
          unawaited(ref.read(playbackProvider.notifier).playNext());
        },
      ),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: l10n.trayQuit, onClick: (_) => _quit()),
    ]);
  }

  /// 语言切换后重建托盘菜单（托盘常驻，不随 Widget 树重建）。
  Future<void> _rebuildMenu() async {
    if (!_trayReady) return;
    await trayManager.setContextMenu(_buildMenu());
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    // Linux 退出绕开 GTK teardown 崩溃，统一走 exit(0)（见 quitApplication）
    await quitApplication(ref);
  }

  // ── WindowListener ─────────────────────────────────────────────

  /// 关闭确认弹窗中「记住我的选择」复选框状态（每次弹窗前重置）。
  bool _closeRemember = false;

  @override
  Future<void> onWindowClose() async {
    // 托盘不可用（未 preventClose）时事件不会进入此处，窗口直接关闭退出；
    // 走到这里说明托盘就绪，按「关闭应用时」偏好分发行为。
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

  /// 每次询问：弹出确认框（后台播放 / 直接退出 + 记忆勾选）。
  Future<void> _askCloseBehavior() async {
    _closeRemember = false;
    final notifier = ref.read(playbackProvider.notifier);
    // 小巧思：退出确认弹窗出现时音量临时降半（营造「要退出了」的氛围），
    // 弹窗关闭后立即恢复原音量——取消/后台播放都保持用户原音量。
    await notifier.duckVolume();
    try {
      // duck 之后再取根 context（避免 async gap 中跨间隙使用 BuildContext）；
      // 为 null（极端场景）时直接返回，finally 会恢复 duck 前音量。
      final nav = rootNavigatorKey.currentContext;
      if (nav == null) return;
      final l10n = ref.read(l10nProvider);
      // 使用点紧贴 mounted 检查（Flutter 官方推荐写法）：SDialog.show 的
      // 参数求值位于 await 之前，guard 消除 use_build_context_synchronously
      // 对跨 async 间隙使用 context 的告警。
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
                Icons.headphones_outlined,
                'background',
              ),
              const SizedBox(height: 8),
              _closeOption(
                dialogContext,
                l10n.settingsCloseBehaviorQuit,
                Icons.power_settings_new_outlined,
                'quit',
              ),
              const SizedBox(height: 12),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () =>
                    setDialogState(() => _closeRemember = !_closeRemember),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
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
                            color: Theme.of(dialogContext)
                                .colorScheme
                                .onSurfaceVariant,
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
      if (choice == null) return; // 点外部 / Esc：维持隐藏到托盘
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
      // 无论选择什么（含真正退出前的瞬间），恢复 duck 前音量
      await notifier.restoreVolume();
    }
  }

  /// 行为选项卡片：点击即携带（行为, 记忆标记）返回。
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
        onTap: () =>
            Navigator.of(dialogContext).pop((value, _closeRemember)),
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
                Icons.chevron_right,
                size: 18,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── TrayListener ───────────────────────────────────────────────

  @override
  void onTrayIconMouseDown() {
    // 左键点击托盘：显示并聚焦主窗口
    // ignore: discarded_futures
    unawaited(_showWindow());
  }

  @override
  Widget build(BuildContext context) {
    // 语言切换后重建托盘菜单
    ref.listen(localeProvider, (prev, next) {
      if (prev != next) unawaited(_rebuildMenu());
    });
    return widget.child;
  }
}
