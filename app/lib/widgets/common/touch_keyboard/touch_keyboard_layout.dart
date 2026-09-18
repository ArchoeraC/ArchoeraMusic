// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 屏幕键盘布局与 evdev 键码（ArchoeraOS 触摸设备用）。
///
/// 键码取 Linux `input-event-codes.h` 的 evdev 值（KEY_*），与合成器
/// `archoera_shell_v1.key` 请求约定一致（并非 Flutter logical key，也不是
/// XKB keycode）。字符键经合成器座位键盘下发，因此输入法（fcitx5）能正常
/// 消费；修饰键（Shift）由本布局在按下字符键前后显式按下/释放。
library;

/// 动作键（不产生字符）。
enum OskAction {
  /// 切换 Shift（一次性；连点两次锁定，第三次取消）。
  shift,

  /// 切换 Ctrl（用于与字符键组合，如 Ctrl+Space 切输入法）。
  ctrl,

  backspace,
  enter,
  space,
  tab,
  escape,

  /// 切换字母/符号层。
  symbols,
  letters,

  /// 切换输入法（Ctrl+Space，fcitx5 默认「激活/取消输入法」）。
  imeToggle,

  /// 收起键盘。
  hide,
}

/// 单个按键。
class OskKey {
  const OskKey(
    this.label, {
    this.evdev,
    this.action,
    this.flex = 1,
    this.shifted,
    this.withShift = false,
    this.compact = false,
  }) : assert(evdev != null || action != null, '按键必须要么有 evdev，要么是动作键');

  /// 显示文本（字母为小写；符号为最终字符）。
  final String label;

  /// evdev 键码（KEY_*）；动作键为 null。
  final int? evdev;

  /// 动作键类型；字符键为 null。
  final OskAction? action;

  /// 横向占比（1 = 标准宽）。
  final double flex;

  /// 按住 Shift 时的显示文本（仅字母键）。
  final String? shifted;

  /// 是否强制带 Shift（符号层里 @ / ? 等 Shift 档字符）。
  final bool withShift;

  /// 是否使用较小的字号（符号 / 动作键）。
  final bool compact;

  const OskKey.actionKey(
    OskAction this.action,
    this.label, {
    this.flex = 1,
    this.compact = true,
  })  : evdev = null,
        shifted = null,
        withShift = false;
}

/// evdev 键码常量（`input-event-codes.h`，仅收录本布局用到的键）。
abstract final class OskEvdev {
  // 控制
  static const int escape = 1;
  static const int backspace = 14;
  static const int tab = 15;
  static const int enter = 28;
  static const int leftCtrl = 29;
  static const int leftShift = 42;
  static const int space = 57;

  // 数字行
  static const int digit1 = 2;
  static const int digit2 = 3;
  static const int digit3 = 4;
  static const int digit4 = 5;
  static const int digit5 = 6;
  static const int digit6 = 7;
  static const int digit7 = 8;
  static const int digit8 = 9;
  static const int digit9 = 10;
  static const int digit0 = 11;
  static const int minus = 12;
  static const int equal = 13;

  // 标点
  static const int leftBrace = 26;
  static const int rightBrace = 27;
  static const int semicolon = 39;
  static const int apostrophe = 40;
  static const int grave = 41;
  static const int backslash = 43;
  static const int comma = 51;
  static const int dot = 52;
  static const int slash = 53;

  // 字母
  static const int q = 16;
  static const int w = 17;
  static const int e = 18;
  static const int r = 19;
  static const int t = 20;
  static const int y = 21;
  static const int u = 22;
  static const int i = 23;
  static const int o = 24;
  static const int p = 25;
  static const int a = 30;
  static const int s = 31;
  static const int d = 32;
  static const int f = 33;
  static const int g = 34;
  static const int h = 35;
  static const int j = 36;
  static const int k = 37;
  static const int l = 38;
  static const int z = 44;
  static const int x = 45;
  static const int c = 46;
  static const int v = 47;
  static const int b = 48;
  static const int n = 49;
  static const int m = 50;
}

/// 数字 / 字母键（Shift 档为大写字母）。
OskKey _letter(String lower, int evdev) =>
    OskKey(lower, evdev: evdev, shifted: lower.toUpperCase());

const OskKey _shiftToggle = OskKey.actionKey(OskAction.shift, 'Shift', flex: 1.6);
const OskKey _backspace = OskKey.actionKey(OskAction.backspace, '⌫', flex: 1.6);
const OskKey _enter = OskKey.actionKey(OskAction.enter, '⏎', flex: 1.6);
const OskKey _space = OskKey.actionKey(OskAction.space, '空格', flex: 5);
const OskKey _tab = OskKey.actionKey(OskAction.tab, 'Tab', flex: 1.4);
const OskKey _escape = OskKey.actionKey(OskAction.escape, 'Esc', flex: 1.2);
const OskKey _toSymbols = OskKey.actionKey(OskAction.symbols, '?123', flex: 1.6);
const OskKey _toLetters = OskKey.actionKey(OskAction.letters, 'ABC', flex: 1.6);
const OskKey _imeToggle = OskKey.actionKey(OskAction.imeToggle, '中/EN', flex: 1.4);

/// 顶部工具行：Esc/Tab + 输入法切换 + 收起。
const List<OskKey> oskTopRow = [
  _escape,
  _tab,
  OskKey.actionKey(OskAction.ctrl, 'Ctrl'),
  _imeToggle,
  OskKey.actionKey(OskAction.hide, '⌄'),
];

/// 字母层。
final List<List<OskKey>> oskLetterRows = [
  [
    _letter('q', OskEvdev.q),
    _letter('w', OskEvdev.w),
    _letter('e', OskEvdev.e),
    _letter('r', OskEvdev.r),
    _letter('t', OskEvdev.t),
    _letter('y', OskEvdev.y),
    _letter('u', OskEvdev.u),
    _letter('i', OskEvdev.i),
    _letter('o', OskEvdev.o),
    _letter('p', OskEvdev.p),
  ],
  [
    _letter('a', OskEvdev.a),
    _letter('s', OskEvdev.s),
    _letter('d', OskEvdev.d),
    _letter('f', OskEvdev.f),
    _letter('g', OskEvdev.g),
    _letter('h', OskEvdev.h),
    _letter('j', OskEvdev.j),
    _letter('k', OskEvdev.k),
    _letter('l', OskEvdev.l),
  ],
  [
    _shiftToggle,
    _letter('z', OskEvdev.z),
    _letter('x', OskEvdev.x),
    _letter('c', OskEvdev.c),
    _letter('v', OskEvdev.v),
    _letter('b', OskEvdev.b),
    _letter('n', OskEvdev.n),
    _letter('m', OskEvdev.m),
    _backspace,
  ],
  [
    _toSymbols,
    const OskKey(',', evdev: OskEvdev.comma),
    _space,
    const OskKey('.', evdev: OskEvdev.dot),
    _enter,
  ],
];

/// 符号层。
final List<List<OskKey>> oskSymbolRows = [
  [
    const OskKey('1', evdev: OskEvdev.digit1),
    const OskKey('2', evdev: OskEvdev.digit2),
    const OskKey('3', evdev: OskEvdev.digit3),
    const OskKey('4', evdev: OskEvdev.digit4),
    const OskKey('5', evdev: OskEvdev.digit5),
    const OskKey('6', evdev: OskEvdev.digit6),
    const OskKey('7', evdev: OskEvdev.digit7),
    const OskKey('8', evdev: OskEvdev.digit8),
    const OskKey('9', evdev: OskEvdev.digit9),
    const OskKey('0', evdev: OskEvdev.digit0),
  ],
  [
    const OskKey('-', evdev: OskEvdev.minus),
    const OskKey('/', evdev: OskEvdev.slash),
    const OskKey(':', evdev: OskEvdev.semicolon, withShift: true),
    const OskKey(';', evdev: OskEvdev.semicolon),
    const OskKey('(', evdev: OskEvdev.digit9, withShift: true),
    const OskKey(')', evdev: OskEvdev.digit0, withShift: true),
    const OskKey(r'$', evdev: OskEvdev.digit4, withShift: true),
    const OskKey('&', evdev: OskEvdev.digit7, withShift: true),
    const OskKey('@', evdev: OskEvdev.digit2, withShift: true),
    const OskKey('"', evdev: OskEvdev.apostrophe, withShift: true),
  ],
  [
    _toLetters,
    const OskKey('.', evdev: OskEvdev.dot),
    const OskKey(',', evdev: OskEvdev.comma),
    const OskKey('?', evdev: OskEvdev.slash, withShift: true),
    const OskKey('!', evdev: OskEvdev.digit1, withShift: true),
    const OskKey("'", evdev: OskEvdev.apostrophe),
    const OskKey('_', evdev: OskEvdev.minus, withShift: true),
    const OskKey('+', evdev: OskEvdev.equal, withShift: true),
    _backspace,
  ],
  [_space, _enter],
];
