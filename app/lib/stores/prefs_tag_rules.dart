// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'app_prefs.dart';

// ── 标签文本规则「自定义预设」偏好键 ──
//
// 存 `List<Map<String, dynamic>>`，每项：
//   { name, op, find, replace, affix, regex, caseSensitive }
// op 为 TagTextOp 的枚举名（字符串）；解析在 UI 层完成，偏好层不依赖
// services/widgets，保持分层清晰。
const tagRuleCustomPresetsKey = 'tagEditor.customPresets';

/// 标签文本规则自定义预设偏好。
extension TagRulePresetsPrefs on AppPrefs {
  /// 用户保存的自定义规则预设（默认空）。
  List<Map<String, dynamic>> get tagRuleCustomPresets {
    final raw = data[tagRuleCustomPresetsKey];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }

  AppPrefs copyWithTagRuleCustomPresets(List<Map<String, dynamic>> presets) =>
      AppPrefs(initialData: {...data, tagRuleCustomPresetsKey: presets});
}
