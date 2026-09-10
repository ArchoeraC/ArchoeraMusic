// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import '../services/shortcuts/shortcut_action.dart';
import 'app_prefs.dart';

// ── 快捷键域键 ──────────────────────────────────────────────────
const shortcutsKey = 'shortcuts.bindings';

/// 快捷键偏好：仅存用户覆盖（actionId → 绑定字符串）；未覆盖用注册表默认。
extension ShortcutPrefs on AppPrefs {
  /// 用户覆盖表（actionId → 绑定字符串）。
  Map<String, String> get shortcutOverrides {
    final raw = data[shortcutsKey];
    if (raw is! Map) return const {};
    return {
      for (final e in raw.entries)
        if (e.key is String && e.value is String) e.key as String: e.value as String,
    };
  }

  /// 单动作覆盖值；无覆盖返回 null。
  String? shortcutOverride(String id) => shortcutOverrides[id];

  /// 动作当前生效绑定（覆盖优先，否则注册表默认；空串 = 未绑定）。
  String bindingFor(ShortcutAction action) =>
      shortcutOverride(action.id) ?? action.defaultBinding;

  /// 设置动作绑定；[binding] 为空/null 表示清除覆盖（回到默认）。
  AppPrefs copyWithShortcut(String id, String? binding) {
    final next = {...shortcutOverrides};
    if (binding == null || binding.isEmpty) {
      next.remove(id);
    } else {
      next[id] = binding;
    }
    return AppPrefs(initialData: {...data, shortcutsKey: next});
  }

  /// 清除全部覆盖（恢复所有默认绑定）。
  AppPrefs copyWithShortcutsCleared() =>
      AppPrefs(initialData: {...data}..remove(shortcutsKey));
}
