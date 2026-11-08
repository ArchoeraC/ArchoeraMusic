// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'app_prefs.dart';

// ── 默认音源（source.default）─────────────────────────────────────

/// 默认音源偏好（`'auto'` = 按登录状态 / 各页历史行为自动选择）。
const defaultSourceKey = 'source.default';

/// 「自动」默认音源哨兵值。
const autoDefaultSource = 'auto';

/// 默认音源偏好。
extension DefaultSourcePrefs on AppPrefs {
  /// 打开「我喜欢」「收藏」「搜索」等可切换音源的页面时默认选中的音源；
  /// [autoDefaultSource] 表示由各页按登录态 / 历史规则自动决定。
  String get defaultSource {
    final v = data[defaultSourceKey];
    return v is String && v.isNotEmpty ? v : autoDefaultSource;
  }

  AppPrefs copyWithDefaultSource(String value) =>
      AppPrefs(initialData: {...data, defaultSourceKey: value});
}
