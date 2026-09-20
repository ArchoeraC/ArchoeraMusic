// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'app_prefs.dart';

// ── 实验性音源 NekoMusic（source.neko. 前缀）──────────────────────

/// 实验性音源总开关（**默认关闭**：关闭时 Neko 不出现在搜索 / 我喜欢 /
/// 收藏的平台列表中，也不发任何请求）。
const nekoEnabledKey = 'source.neko.enabled';

/// 实验性音源偏好。
extension NekoPrefs on AppPrefs {
  /// 是否启用 Neko 实验性音源（默认关）。
  bool get nekoEnabled => data[nekoEnabledKey] as bool? ?? false;

  AppPrefs copyWithNekoEnabled(bool value) =>
      AppPrefs(initialData: {...data, nekoEnabledKey: value});
}
