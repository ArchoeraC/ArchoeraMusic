// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 触摸屏软件键盘（ArchoeraOS 内置 OSK）。
///
/// 背景：ArchoeraOS 的 kiosk 合成器面向触摸设备，但系统本身不提供屏幕键盘。
/// 本组件在应用内自绘键盘，按键经平台桥接注入合成器座位键盘
/// （`archoera_shell_v1.key`，见 `SystemOsSession.key`），因此输入法（fcitx5）
/// 能像处理物理键盘一样处理这些按键——拼音、候选与中英切换全部可用。
///
/// 显示策略：
/// - 仅当合成器通告 [OsCapability.keyboard] 能力时启用（普通桌面会话不显示）；
/// - **触摸**聚焦文本输入框时自动弹出，失焦自动收起；可按 ⌄ 手动收起；
/// - 桌面鼠标/键盘用户不会被打扰（仅追踪 [PointerDeviceKind.touch]）。
library;

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../services/platform/os_session.dart';
import '../../../services/platform/system_os.dart';
import 'touch_keyboard_layout.dart';

/// 键盘是否可见（由 [TouchKeyboardHost] 依据焦点 + 触摸输入维护）。
class TouchKeyboardVisibility extends Notifier<bool> {
  @override
  bool build() => false;

  void setValue(bool value) => state = value;
}

final touchKeyboardVisibilityProvider =
    NotifierProvider<TouchKeyboardVisibility, bool>(TouchKeyboardVisibility.new);

/// 键盘高度（逻辑像素）：随屏幕短边收敛，小屏不至于占据半屏、大屏不至于过矮。
double touchKeyboardHeight(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return (size.shortestSide * 0.42).clamp(190.0, 320.0);
}

/// 根级宿主：包裹应用子树，追踪触摸输入与文本焦点，按需在底部叠加键盘。
///
/// 可见时会同步抬高 `MediaQuery.viewInsets.bottom`，使 `Scaffold`/对话框
/// 让出键盘空间（聚焦输入框自动滚动到键盘之上）。
class TouchKeyboardHost extends ConsumerStatefulWidget {
  const TouchKeyboardHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TouchKeyboardHost> createState() => _TouchKeyboardHostState();
}

class _TouchKeyboardHostState extends ConsumerState<TouchKeyboardHost> {
  /// 最近一次交互是否来自触摸：只有触摸用户才自动弹出屏幕键盘。
  bool _lastInputTouch = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    super.dispose();
  }

  bool get _supported =>
      (ref.read(osCapabilitiesProvider) & OsCapability.keyboard) != 0;

  void _onFocusChanged() {
    if (!mounted || !_supported) return;
    final editing = _isTextEditing();
    final visible = ref.read(touchKeyboardVisibilityProvider);
    final notifier = ref.read(touchKeyboardVisibilityProvider.notifier);
    if (editing && _lastInputTouch && !visible) {
      notifier.setValue(true);
    } else if (!editing && visible) {
      notifier.setValue(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final supported =
        (ref.watch(osCapabilitiesProvider) & OsCapability.keyboard) != 0;
    final visible = supported && ref.watch(touchKeyboardVisibilityProvider);
    final height = touchKeyboardHeight(context);
    final media = MediaQuery.of(context);
    final insets = media.viewInsets.copyWith(bottom: visible ? height : null);

    return Listener(
      onPointerDown: (event) {
        if (event.kind == PointerDeviceKind.touch) _lastInputTouch = true;
      },
      child: MediaQuery(
        data: media.copyWith(viewInsets: insets),
        child: Stack(
          children: [
            Positioned.fill(child: widget.child),
            if (visible)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: TouchKeyboard(height: height),
              ),
          ],
        ),
      ),
    );
  }
}

/// 焦点是否落在文本输入控件上。
///
/// 与 `app_shortcuts.dart` 同源：TextField 的 focusNode 实际附着在内部
/// `Focus` 上，`primaryFocus.context.widget` 是 Focus 而非 EditableText，
/// 需同时检查祖先链。
bool _isTextEditing() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  return ctx.widget is EditableText ||
      ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// 软件键盘本体。
class TouchKeyboard extends ConsumerStatefulWidget {
  const TouchKeyboard({super.key, required this.height});

  final double height;

  @override
  ConsumerState<TouchKeyboard> createState() => _TouchKeyboardState();
}

class _TouchKeyboardState extends ConsumerState<TouchKeyboard> {
  bool _shift = false;

  /// Shift 连点锁定（锁定后输入一个字符不自动取消）。
  bool _shiftLock = false;
  bool _ctrl = false;
  bool _symbols = false;

  SystemOsSession get _os => ref.read(osSessionControllerProvider);

  void _send(int evdev, bool down) => _os.key(evdev, down ? 1 : 0);

  void _tap(int evdev) {
    _send(evdev, true);
    _send(evdev, false);
  }

  void _onKey(OskKey key) {
    final action = key.action;
    if (action != null) {
      _onAction(action);
      return;
    }
    _onChar(key);
  }

  void _onChar(OskKey key) {
    final shifted = key.withShift || (_shift && key.shifted != null);
    if (shifted) _send(OskEvdev.leftShift, true);
    _tap(key.evdev!);
    if (shifted) _send(OskEvdev.leftShift, false);
    if (_shift && !_shiftLock) setState(() => _shift = false);
  }

  void _onAction(OskAction action) {
    switch (action) {
      case OskAction.shift:
        setState(() {
          if (!_shift) {
            _shift = true;
            _shiftLock = false;
          } else if (!_shiftLock) {
            _shiftLock = true;
          } else {
            _shift = false;
            _shiftLock = false;
          }
        });
      case OskAction.ctrl:
        setState(() => _ctrl = !_ctrl);
        _send(OskEvdev.leftCtrl, _ctrl);
      case OskAction.backspace:
        _tap(OskEvdev.backspace);
      case OskAction.enter:
        _tap(OskEvdev.enter);
      case OskAction.space:
        _tap(OskEvdev.space);
      case OskAction.tab:
        _tap(OskEvdev.tab);
      case OskAction.escape:
        _tap(OskEvdev.escape);
      case OskAction.symbols:
        setState(() => _symbols = true);
      case OskAction.letters:
        setState(() => _symbols = false);
      case OskAction.imeToggle:
        // fcitx5 默认「激活/取消输入法」快捷键即 Ctrl+Space。
        _send(OskEvdev.leftCtrl, true);
        _tap(OskEvdev.space);
        _send(OskEvdev.leftCtrl, false);
      case OskAction.hide:
        ref.read(touchKeyboardVisibilityProvider.notifier).setValue(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _symbols ? oskSymbolRows : oskLetterRows;
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            children: [
              Expanded(child: _row(oskTopRow)),
              for (final row in rows) Expanded(child: _row(row)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(List<OskKey> keys) {
    return Row(
      children: [
        for (final key in keys)
          Expanded(
            flex: (key.flex * 100).round(),
            child: _key(key),
          ),
      ],
    );
  }

  Widget _key(OskKey key) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isShift = key.action == OskAction.shift;
    final isCtrl = key.action == OskAction.ctrl;
    final active = (isShift && _shift) || (isCtrl && _ctrl);

    final label = (!_symbols && key.shifted != null && (_shift || _shiftLock))
        ? key.shifted!
        : key.label;

    final background = active
        ? scheme.primaryContainer
        : (key.action != null ? scheme.surfaceContainer : scheme.surface);
    final foreground =
        active ? scheme.onPrimaryContainer : scheme.onSurface;

    return Padding(
      padding: const EdgeInsets.all(2),
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _onKey(key),
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(
                color: foreground,
                fontSize: key.compact ? 13 : 18,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
