import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/playback/playback_notifier.dart';

/// 焦点是否落在文本输入控件上。
///
/// 注意：TextField 的 focusNode 实际附着在内部 `Focus` widget 上，
/// `primaryFocus.context.widget` 是 Focus 而非 EditableText，直接做
/// `widget is EditableText` 会漏判，导致输入框聚焦时快捷键不让位
/// （空格被截走 / Ctrl+F、Esc 触发导航）。故同时检查祖先链。
bool _isTextEditing() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  return ctx.widget is EditableText ||
      ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// 应用级快捷键（对齐原版 hotkey 体系的核心播放/导航动作）。
///
/// 实现：根级 [Shortcuts] + [Actions]。Flutter 按键分发按最近匹配优先，
/// 输入框内的方向键/回车等由 EditableText 的快捷键先于本层消费。
/// 空格不在 EditableText 快捷键内，若本层直接吞掉会截走输入框的空格
/// 字符，故 [Space] 走自定义 [_PlayPauseAction]：输入框聚焦时
/// `consumesKey` 返回 false（事件以 skipRemainingHandlers 继续进入
/// 文本输入通道，空格照常输入且不触发播放/暂停）。
///
/// 内置：
///  - Space        播放/暂停（输入框聚焦时让位）
///  - ← / →        后退/前进 10s（有播放源时）
///  - Ctrl/Cmd+↑/↓ 音量 +/- 0.05（对齐 SPlayer-Next volumeUp/volumeDown）
///  - Ctrl/Cmd+F   搜索页（隐藏分支）
///  - Ctrl/Cmd+L   音乐库
///  - Esc          返回（关闭弹窗/全屏播放器）
class AppShortcuts extends ConsumerWidget {
  const AppShortcuts({super.key, required this.child});

  final Widget child;

  static const _seekStep = Duration(seconds: 10);

  /// 音量步进（对齐 SPlayer-Next VOLUME_STEP = 0.05）。
  static const double _volumeStep = 0.05;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Shortcuts(
      shortcuts: {
        SingleActivator(LogicalKeyboardKey.space): _PlayPauseIntent(),
        SingleActivator(LogicalKeyboardKey.arrowLeft): _SeekBackIntent(),
        SingleActivator(LogicalKeyboardKey.arrowRight): _SeekForwardIntent(),
        SingleActivator(LogicalKeyboardKey.escape): _BackIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.arrowUp):
            _VolumeUpIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.arrowDown):
            _VolumeDownIntent(),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.arrowUp):
            _VolumeUpIntent(),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.arrowDown):
            _VolumeDownIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyF):
            _SearchIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyL):
            _LibraryIntent(),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyF):
            _SearchIntent(),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyL):
            _LibraryIntent(),
      },
      child: Actions(
        actions: {
          _PlayPauseIntent: _PlayPauseAction(ref),
          _SeekBackIntent: CallbackAction<_SeekBackIntent>(
            onInvoke: (_) => _seek(ref, -_seekStep)),
          _SeekForwardIntent: CallbackAction<_SeekForwardIntent>(
            onInvoke: (_) => _seek(ref, _seekStep)),
          _VolumeUpIntent: CallbackAction<_VolumeUpIntent>(
            onInvoke: (_) {
              if (_editing) return null;
              _adjustVolume(ref, _volumeStep);
              return null;
            },
          ),
          _VolumeDownIntent: CallbackAction<_VolumeDownIntent>(
            onInvoke: (_) {
              if (_editing) return null;
              _adjustVolume(ref, -_volumeStep);
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
        child: Focus(
          autofocus: true,
          child: child,
        ),
      ),
    );
  }

  /// 主焦点是否落在文本输入（导航类快捷键让位，避免输入中被劫持）。
  bool get _editing => _isTextEditing();

  void _seek(WidgetRef ref, Duration delta) {
    // 输入框内方向键是光标移动，不触发 seek
    if (_editing) return;
    final notifier = ref.read(playbackProvider.notifier);
    final s = ref.read(playbackProvider);
    if (s.source == null) return;
    var target = s.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > s.duration) target = s.duration;
    notifier.seek(target);
  }

  /// 音量微调（步进 +/-，收敛 0~1；对齐 SPlayer-Next volumeUp/volumeDown）。
  void _adjustVolume(WidgetRef ref, double delta) {
    final notifier = ref.read(playbackProvider.notifier);
    final s = ref.read(playbackProvider);
    // ignore: discarded_futures
    notifier.setVolume(s.volume + delta);
  }
}

class _PlayPauseIntent extends Intent {}
class _SeekBackIntent extends Intent {}
class _SeekForwardIntent extends Intent {}
class _VolumeUpIntent extends Intent {}
class _VolumeDownIntent extends Intent {}
class _SearchIntent extends Intent {}
class _LibraryIntent extends Intent {}
class _BackIntent extends Intent {}

/// 空格播放/暂停的 Action（自定义 [consumesKey]）。
///
/// 输入框聚焦时既不触发播放/暂停，也**不消费空格键**——`consumesKey`
/// 返回 false 使 [KeyEventResult] 为 skipRemainingHandlers，事件继续
/// 进入平台文本输入通道，空格字符正常输入（若默认 consumesKey=true
/// 会把按键标记 handled，搜索框里的空格会被本层截走）。
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
