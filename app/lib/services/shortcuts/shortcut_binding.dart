// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 快捷键绑定：字符串 ↔ Flutter [ShortcutActivator] 的解析 / 序列化 / 显示。
///
/// 存储格式：修饰键（ctrl/alt/shift/meta）与主键以 `+` 连接，修饰键顺序
/// 规范化（ctrl, alt, shift, meta），如 `ctrl+shift+k`、`space`、`f5`、
/// `mediaPlayPause`。无法命名的键回退 `key:<keyId>`（仍可显示 keyLabel）。
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 常用主键：token → LogicalKeyboardKey。覆盖字母/数字/功能键/编辑键/
/// 方向键/标点/媒体键/浏览器键，供用户捕获时规范化命名。
final Map<String, LogicalKeyboardKey> _keyByToken = () {
  final m = <String, LogicalKeyboardKey>{};
  void put(String token, LogicalKeyboardKey key) => m[token] = key;

  put('space', LogicalKeyboardKey.space);
  put('enter', LogicalKeyboardKey.enter);
  put('numpadEnter', LogicalKeyboardKey.numpadEnter);
  put('escape', LogicalKeyboardKey.escape);
  put('tab', LogicalKeyboardKey.tab);
  put('backspace', LogicalKeyboardKey.backspace);
  put('delete', LogicalKeyboardKey.delete);
  put('insert', LogicalKeyboardKey.insert);
  put('home', LogicalKeyboardKey.home);
  put('end', LogicalKeyboardKey.end);
  put('pageUp', LogicalKeyboardKey.pageUp);
  put('pageDown', LogicalKeyboardKey.pageDown);
  put('arrowUp', LogicalKeyboardKey.arrowUp);
  put('arrowDown', LogicalKeyboardKey.arrowDown);
  put('arrowLeft', LogicalKeyboardKey.arrowLeft);
  put('arrowRight', LogicalKeyboardKey.arrowRight);
  put('capsLock', LogicalKeyboardKey.capsLock);
  put('printScreen', LogicalKeyboardKey.printScreen);
  put('pause', LogicalKeyboardKey.pause);
  put('contextMenu', LogicalKeyboardKey.contextMenu);

  put('minus', LogicalKeyboardKey.minus);
  put('equal', LogicalKeyboardKey.equal);
  put('bracketLeft', LogicalKeyboardKey.bracketLeft);
  put('bracketRight', LogicalKeyboardKey.bracketRight);
  put('backslash', LogicalKeyboardKey.backslash);
  put('semicolon', LogicalKeyboardKey.semicolon);
  put('quote', LogicalKeyboardKey.quote);
  put('comma', LogicalKeyboardKey.comma);
  put('period', LogicalKeyboardKey.period);
  put('slash', LogicalKeyboardKey.slash);
  put('backquote', LogicalKeyboardKey.backquote);

  // 字母 a-z / 数字 0-9（keyId 即 ASCII 码，用 findKeyByKeyId 取得标准键）
  for (var i = 0; i < 26; i++) {
    final k = LogicalKeyboardKey.findKeyByKeyId(0x61 + i);
    if (k != null) put(String.fromCharCode(0x61 + i), k);
  }
  for (var i = 0; i < 10; i++) {
    final k = LogicalKeyboardKey.findKeyByKeyId(0x30 + i);
    if (k != null) put('$i', k);
  }
  // 功能键
  put('f1', LogicalKeyboardKey.f1);
  put('f2', LogicalKeyboardKey.f2);
  put('f3', LogicalKeyboardKey.f3);
  put('f4', LogicalKeyboardKey.f4);
  put('f5', LogicalKeyboardKey.f5);
  put('f6', LogicalKeyboardKey.f6);
  put('f7', LogicalKeyboardKey.f7);
  put('f8', LogicalKeyboardKey.f8);
  put('f9', LogicalKeyboardKey.f9);
  put('f10', LogicalKeyboardKey.f10);
  put('f11', LogicalKeyboardKey.f11);
  put('f12', LogicalKeyboardKey.f12);

  // 媒体 / 浏览器 / 音量键
  put('mediaPlayPause', LogicalKeyboardKey.mediaPlayPause);
  put('mediaStop', LogicalKeyboardKey.mediaStop);
  put('mediaTrackNext', LogicalKeyboardKey.mediaTrackNext);
  put('mediaTrackPrevious', LogicalKeyboardKey.mediaTrackPrevious);
  put('audioVolumeUp', LogicalKeyboardKey.audioVolumeUp);
  put('audioVolumeDown', LogicalKeyboardKey.audioVolumeDown);
  put('audioVolumeMute', LogicalKeyboardKey.audioVolumeMute);
  put('browserBack', LogicalKeyboardKey.browserBack);
  put('browserForward', LogicalKeyboardKey.browserForward);
  put('browserHome', LogicalKeyboardKey.browserHome);
  put('browserSearch', LogicalKeyboardKey.browserSearch);
  return m;
}();

/// keyId → token（反查，捕获时用）。
final Map<int, String> _tokenByKeyId = {
  for (final e in _keyByToken.entries) e.value.keyId: e.key,
};

/// 解析绑定字符串 → [ShortcutActivator]；非法返回 null。
ShortcutActivator? parseBinding(String raw) {
  final parts = raw
      .split('+')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;

  final keyToken = parts.removeLast();
  var control = false, alt = false, shift = false, meta = false;
  for (final p in parts) {
    switch (p.toLowerCase()) {
      case 'ctrl':
      case 'control':
        control = true;
      case 'alt':
      case 'option':
        alt = true;
      case 'shift':
        shift = true;
      case 'meta':
      case 'cmd':
      case 'super':
        meta = true;
      default:
        return null; // 未知修饰键
    }
  }

  final key = _resolveKey(keyToken);
  if (key == null) return null;
  // 单键避免误吞系统级修饰键组合（如单独 Shift）
  if (key == LogicalKeyboardKey.control ||
      key == LogicalKeyboardKey.alt ||
      key == LogicalKeyboardKey.shift ||
      key == LogicalKeyboardKey.meta) {
    return null;
  }
  return SingleActivator(
    key,
    control: control,
    alt: alt,
    shift: shift,
    meta: meta,
  );
}

LogicalKeyboardKey? _resolveKey(String token) {
  final direct = _keyByToken[token];
  if (direct != null) return direct;
  if (token.startsWith('key:')) {
    final id = int.tryParse(token.substring(4));
    if (id == null) return null;
    return LogicalKeyboardKey.findKeyByKeyId(id);
  }
  return null;
}

/// [ShortcutActivator] → 绑定字符串；不可序列化返回 null。
String? encodeBinding(ShortcutActivator? activator) {
  if (activator is! SingleActivator) return null;
  final mods = <String>[];
  if (activator.control) mods.add('ctrl');
  if (activator.alt) mods.add('alt');
  if (activator.shift) mods.add('shift');
  if (activator.meta) mods.add('meta');
  final token = _tokenByKeyId[activator.trigger.keyId] ??
      'key:${activator.trigger.keyId}';
  return [...mods, token].join('+');
}

/// 特殊键显示别名（keyLabel 为空白/无意义时用）。
const _displayOverrides = <String, String>{
  'space': 'Space',
  'escape': 'Esc',
  'enter': 'Enter',
  'numpadEnter': 'NumEnter',
  'tab': 'Tab',
  'backspace': 'Backspace',
  'delete': 'Del',
  'insert': 'Ins',
  'home': 'Home',
  'end': 'End',
  'pageUp': 'PgUp',
  'pageDown': 'PgDn',
  'capsLock': 'Caps',
  'printScreen': 'PrtSc',
  'arrowUp': '↑',
  'arrowDown': '↓',
  'arrowLeft': '←',
  'arrowRight': '→',
  'mediaPlayPause': '⏯',
  'mediaStop': '⏹',
  'mediaTrackNext': '⏭',
  'mediaTrackPrevious': '⏮',
  'audioVolumeUp': 'Vol+',
  'audioVolumeDown': 'Vol-',
  'audioVolumeMute': 'Mute',
};

/// 单个逻辑键的显示名（优先 keyLabel，回退别名 / token / #id）。
String keyDisplayName(LogicalKeyboardKey key) {
  final label = key.keyLabel;
  if (label.isNotEmpty && label != ' ') return label;
  final token = _tokenByKeyId[key.keyId];
  if (token != null) return _displayOverrides[token] ?? token;
  return '#${key.keyId}';
}

/// 绑定字符串的显示文本（平台感知修饰键符号）。
String formatBinding(String raw, {required bool isMac}) {
  final parts = raw.split('+').where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return '';
  final out = <String>[];
  for (final p in parts) {
    switch (p) {
      case 'ctrl':
        out.add(isMac ? '⌃' : 'Ctrl');
      case 'alt':
        out.add(isMac ? '⌥' : 'Alt');
      case 'shift':
        out.add(isMac ? '⇧' : 'Shift');
      case 'meta':
        out.add(isMac ? '⌘' : 'Super');
      default:
        final key = _resolveKey(p);
        out.add(key != null ? keyDisplayName(key) : p);
    }
  }
  return out.join(isMac ? ' ' : ' + ');
}
