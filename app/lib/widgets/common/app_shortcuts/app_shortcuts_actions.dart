// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../app_shortcuts.dart';

extension _AppShortcutsView on AppShortcuts {
  Widget _buildAppShortcuts(BuildContext context, WidgetRef ref) {
    return Shortcuts(
      shortcuts: {
        SingleActivator(LogicalKeyboardKey.space): const _PlayPauseIntent(),
        SingleActivator(LogicalKeyboardKey.arrowLeft): const _SeekBackIntent(),
        SingleActivator(LogicalKeyboardKey.arrowRight):
            const _SeekForwardIntent(),
        SingleActivator(LogicalKeyboardKey.escape): const _BackIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.arrowUp):
            const _VolumeUpIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.arrowDown):
            const _VolumeDownIntent(),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.arrowUp):
            const _VolumeUpIntent(),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.arrowDown):
            const _VolumeDownIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyF):
            const _SearchIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyL):
            const _LibraryIntent(),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyF):
            const _SearchIntent(),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyL):
            const _LibraryIntent(),
      },
      child: Actions(
        actions: {
          _PlayPauseIntent: _PlayPauseAction(ref),
          _SeekBackIntent: CallbackAction<_SeekBackIntent>(
            onInvoke: (_) => _seek(ref, -AppShortcuts._seekStep),
          ),
          _SeekForwardIntent: CallbackAction<_SeekForwardIntent>(
            onInvoke: (_) => _seek(ref, AppShortcuts._seekStep),
          ),
          _VolumeUpIntent: CallbackAction<_VolumeUpIntent>(
            onInvoke: (_) {
              if (_editing) return null;
              _adjustVolume(ref, AppShortcuts._volumeStep);
              return null;
            },
          ),
          _VolumeDownIntent: CallbackAction<_VolumeDownIntent>(
            onInvoke: (_) {
              if (_editing) return null;
              _adjustVolume(ref, -AppShortcuts._volumeStep);
              return null;
            },
          ),
          _SearchIntent: CallbackAction<_SearchIntent>(
            onInvoke: (_) {
              if (_editing) return null;
              context.go('/search');
              return null;
            },
          ),
          _LibraryIntent: CallbackAction<_LibraryIntent>(
            onInvoke: (_) {
              if (_editing) return null;
              context.go('/library');
              return null;
            },
          ),
          _BackIntent: CallbackAction<_BackIntent>(
            onInvoke: (_) {
              if (_editing) return null;
              final navigator = Navigator.of(context);
              if (navigator.canPop()) navigator.pop();
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

class _PlayPauseIntent extends Intent {
  const _PlayPauseIntent();
}

class _SeekBackIntent extends Intent {
  const _SeekBackIntent();
}

class _SeekForwardIntent extends Intent {
  const _SeekForwardIntent();
}

class _VolumeUpIntent extends Intent {
  const _VolumeUpIntent();
}

class _VolumeDownIntent extends Intent {
  const _VolumeDownIntent();
}

class _SearchIntent extends Intent {
  const _SearchIntent();
}

class _LibraryIntent extends Intent {
  const _LibraryIntent();
}

class _BackIntent extends Intent {
  const _BackIntent();
}

class _PlayPauseAction extends Action<_PlayPauseIntent> {
  _PlayPauseAction(this.ref);

  final WidgetRef ref;

  bool get _editing => _isTextEditing();

  @override
  Object? invoke(_PlayPauseIntent intent) {
    if (_editing) return null;
    ref.read(playbackProvider.notifier).toggle();
    return null;
  }

  @override
  bool consumesKey(_PlayPauseIntent intent) => !_editing;
}
