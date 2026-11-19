// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'app_prefs.dart';

// ── 实验性音源 NekoMusic（source.neko. 前缀）──────────────────────

/// 实验性音源总开关（**默认关闭**：关闭时 Neko 不出现在搜索 / 我喜欢 /
/// 收藏的平台列表中，也不发任何请求）。
const nekoEnabledKey = 'source.neko.enabled';

/// 应用内账号密码登录开关（**默认关闭**，需用户显式打开）。
///
/// 打开后登录框才提供「账号密码」页，且 NekoAuth 请求会附带与站点同源的
/// `Origin` 头（兼容可能存在的一方可信来源校验）。关闭时只提供扫码登录。
const nekoPasswordLoginKey = 'source.neko.passwordLogin';

/// 实验性音源偏好。
extension NekoPrefs on AppPrefs {
  /// 是否启用 Neko 实验性音源（默认关）。
  bool get nekoEnabled => data[nekoEnabledKey] as bool? ?? false;

  /// 是否启用应用内账号密码登录（默认关）。
  bool get nekoPasswordLoginEnabled =>
      data[nekoPasswordLoginKey] as bool? ?? false;

  AppPrefs copyWithNekoEnabled(bool value) =>
      AppPrefs(initialData: {...data, nekoEnabledKey: value});

  AppPrefs copyWithNekoPasswordLogin(bool value) =>
      AppPrefs(initialData: {...data, nekoPasswordLoginKey: value});
}

/// 音源是否可用：仅取决于用户开关。
///
/// NekoMusic 已取消第三方客户端 `client_id` / 实例签名要求，不再需要构建期
/// 注入身份；登录支持「扫码」与「应用内账号密码」（后者需用户在设置里单独
/// 打开，链路见 `NekoAuthClient`），两者都无需系统浏览器。
bool nekoSourceUsable(AppPrefs prefs) => prefs.nekoEnabled;
