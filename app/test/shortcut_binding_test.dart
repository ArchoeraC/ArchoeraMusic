// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:archoera_music/services/shortcuts/shortcut_action.dart';
import 'package:archoera_music/services/shortcuts/shortcut_binding.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parse/encode round-trip', () {
    for (final raw in ['space', 'escape', 'arrowLeft', 'ctrl+f', 'ctrl+l']) {
      final a = parseBinding(raw);
      expect(a, isNotNull, reason: raw);
      expect(encodeBinding(a), raw, reason: raw);
    }
  });

  test('modifier order canonicalized', () {
    final a = parseBinding('shift+ctrl+k');
    expect(encodeBinding(a), 'ctrl+shift+k');
  });

  test('invalid binding rejected', () {
    expect(parseBinding(''), isNull);
    expect(parseBinding('ctrl'), isNull);
    expect(parseBinding('ctrl+unknownkey'), isNull);
  });

  test('formatBinding displays labels', () {
    expect(formatBinding('space', isMac: false), 'Space');
    expect(formatBinding('ctrl+arrowUp', isMac: false), contains('Ctrl'));
  });

  test('defaults cover original built-ins', () {
    expect(ShortcutAction.playPause.defaultBinding, 'space');
    expect(ShortcutAction.goSearch.defaultBinding, 'ctrl+f');
    expect(ShortcutAction.goLibrary.defaultBinding, 'ctrl+l');
    expect(ShortcutAction.back.defaultBinding, 'escape');
  });

  test('parseBinding 可关闭系统自动重复', () {
    final repeating = parseBinding('ctrl+k');
    final oneShot = parseBinding('ctrl+k', includeRepeats: false);
    expect((repeating! as SingleActivator).includeRepeats, isTrue);
    expect((oneShot! as SingleActivator).includeRepeats, isFalse);
    // 关闭重复不影响编码往返。
    expect(encodeBinding(oneShot), 'ctrl+k');
  });

  test('开关/导航类动作不响应按键重复，持续型动作响应', () {
    for (final action in [
      ShortcutAction.openPlayer,
      ShortcutAction.back,
      ShortcutAction.goHome,
      ShortcutAction.playPause,
      ShortcutAction.muteToggle,
    ]) {
      expect(action.repeats, isFalse, reason: action.id);
    }
    for (final action in [
      ShortcutAction.seekForward,
      ShortcutAction.seekBackward,
      ShortcutAction.volumeUp,
      ShortcutAction.volumeDown,
      ShortcutAction.next,
      ShortcutAction.previous,
    ]) {
      expect(action.repeats, isTrue, reason: action.id);
    }
  });

  test('all actions have unique ids', () {
    final ids = ShortcutAction.values.map((a) => a.id).toSet();
    expect(ids.length, ShortcutAction.values.length);
  });

  test('every default binding parses', () {
    for (final a in ShortcutAction.values) {
      if (a.defaultBinding.isEmpty) continue;
      expect(parseBinding(a.defaultBinding), isNotNull, reason: a.id);
    }
  });

  test('no default binding collisions', () {
    final seen = <String>{};
    for (final a in ShortcutAction.values) {
      if (a.defaultBinding.isEmpty) continue;
      expect(seen.add(a.defaultBinding), isTrue, reason: a.defaultBinding);
    }
  });

  test('LogicalKeyboardKey import sanity', () {
    expect(LogicalKeyboardKey.space.keyId, isPositive);
  });
}
