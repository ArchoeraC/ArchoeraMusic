// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../app_shortcuts.dart';

extension _AppShortcutsView on AppShortcuts {
  Widget _buildAppShortcuts(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(appPrefsProvider);
    // 绑定表：action → activator（首个占用者优先，重复绑定后到者忽略；
    // 设置页会对冲突给出提示）。
    final shortcuts = <ShortcutActivator, Intent>{};
    for (final action in ShortcutAction.values) {
      final raw = prefs.bindingFor(action);
      if (raw.isEmpty) continue;
      final activator = parseBinding(raw);
      if (activator == null) continue;
      shortcuts.putIfAbsent(activator, () => _ShortcutIntent(action));
    }
    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: {_ShortcutIntent: _ShortcutAction(ref)},
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

class _ShortcutIntent extends Intent {
  const _ShortcutIntent(this.action);

  final ShortcutAction action;
}

/// 统一动作处理器：按 [ShortcutAction] 分发（播放/导航/队列）。
class _ShortcutAction extends Action<_ShortcutIntent> {
  _ShortcutAction(this.ref);

  final WidgetRef ref;

  /// 静音前的音量（用于恢复）。
  double? _muteMemory;

  bool get _editing => _isTextEditing();

  @override
  bool consumesKey(_ShortcutIntent intent) => !_editing;

  @override
  Object? invoke(_ShortcutIntent intent) {
    if (_editing) return null;
    _run(intent.action);
    return null;
  }

  void _run(ShortcutAction action) {
    final pb = ref.read(playbackProvider.notifier);
    final s = ref.read(playbackProvider);
    switch (action) {
      // ── 播放控制 ──
      case ShortcutAction.playPause:
        pb.toggle();
      case ShortcutAction.play:
        if (!s.playing && s.source != null) pb.toggle();
      case ShortcutAction.pause:
        if (s.playing) pb.toggle();
      case ShortcutAction.stop:
        // ignore: discarded_futures
        pb.stop();
      case ShortcutAction.next:
        // ignore: discarded_futures
        pb.playNext();
      case ShortcutAction.previous:
        // ignore: discarded_futures
        pb.playPrevious();
      case ShortcutAction.likeToggle:
        final track = s.track;
        if (track != null) {
          // ignore: discarded_futures
          ref.read(likeControllerProvider).toggle(track);
        }
      case ShortcutAction.shuffleToggle:
        pb.toggleShuffle();
      case ShortcutAction.repeatCycle:
        pb.cycleRepeatMode();
      case ShortcutAction.reload:
        // ignore: discarded_futures
        pb.reload();

      // ── 快进 / 快退 ──
      case ShortcutAction.seekBackward:
        AppShortcuts.seek(ref, -AppShortcuts.seekStep);
      case ShortcutAction.seekForward:
        AppShortcuts.seek(ref, AppShortcuts.seekStep);
      case ShortcutAction.seekBackwardLong:
        AppShortcuts.seek(ref, -AppShortcuts.seekLongStep);
      case ShortcutAction.seekForwardLong:
        AppShortcuts.seek(ref, AppShortcuts.seekLongStep);

      // ── 音量 ──
      case ShortcutAction.volumeUp:
        AppShortcuts.adjustVolume(ref, AppShortcuts.volumeStep);
      case ShortcutAction.volumeDown:
        AppShortcuts.adjustVolume(ref, -AppShortcuts.volumeStep);
      case ShortcutAction.muteToggle:
        if (s.volume > 0) {
          _muteMemory = s.volume;
          // ignore: discarded_futures
          pb.setVolume(0);
        } else {
          // ignore: discarded_futures
          pb.setVolume(_muteMemory ?? 1.0);
        }

      // ── 队列 ──
      case ShortcutAction.jumpToFirst:
        if (s.queue.isNotEmpty) {
          // ignore: discarded_futures
          pb.playAtIndex(0);
        }
      case ShortcutAction.jumpToLast:
        if (s.queue.isNotEmpty) {
          // ignore: discarded_futures
          pb.playAtIndex(s.queue.length - 1);
        }
      case ShortcutAction.clearQueue:
        // ignore: discarded_futures
        pb.clearQueue();

      // ── 导航 ──
      // 注意：AppShortcuts 位于 MaterialApp.router 的 builder 内，其 context 在
      // Router/Navigator 之上，`context.go/push` 会抛「No GoRouter found in
      // context」。故一律用全局 appRouter / rootNavigatorKey 导航。
      case ShortcutAction.openPlayer:
        // ignore: discarded_futures
        appRouter.push('/player');
      case ShortcutAction.openSettings:
        final ctx = rootNavigatorKey.currentContext;
        if (ctx != null) showSettingsDialog(ctx);
      case ShortcutAction.back:
        final navigator = rootNavigatorKey.currentState;
        if (navigator != null && navigator.canPop()) navigator.pop();
      case ShortcutAction.goHome:
      case ShortcutAction.goLibrary:
      case ShortcutAction.goSearch:
      case ShortcutAction.goLiked:
      case ShortcutAction.goFavorites:
      case ShortcutAction.goHistory:
      case ShortcutAction.goDownload:
      case ShortcutAction.goStreaming:
        final route = action.route;
        if (route != null) {
          // ignore: discarded_futures
          appRouter.go(route);
        }
    }
  }
}
