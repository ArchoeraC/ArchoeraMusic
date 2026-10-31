// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import '../apis/neko/neko_client_config.dart';
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

/// 音源是否可用：用户开启 **且** 构建期注入了我们自己的 `client_id`。
///
/// 未配置 client_id 的构建一律视为不可用（fail-closed）：不注册实例、不发请求、
/// 搜索 / 我喜欢 / 收藏的源列表里也不出现该项。
bool nekoSourceUsable(AppPrefs prefs) =>
    prefs.nekoEnabled && nekoClientIdentityConfigured;
