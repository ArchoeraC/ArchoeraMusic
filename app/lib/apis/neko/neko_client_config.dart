// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 第三方客户端身份配置。
///
/// `client_id` 由 NekoMusic 后台按 **public client**（平台 `pc`）签发，归属
/// ArchoeraC。虽然它是公开标识（会随发行包分发、不构成伪造请求的风险——请求
/// 真伪由每安装实例的 EC 私钥签名决定），但仍**不写进源码仓库**：
///
/// - 本地构建：`flutter build … --dart-define=NEKO_CLIENT_ID=nkc_pub_…`
/// - CI：仓库 **Secret** `NEKO_CLIENT_ID`（日志自动打码），构建时注入
///
/// 未注入时本源整体禁用（fail-closed：不注册、不发请求、UI 不显示入口）。
library;

/// NekoMusic 客户端标识（公开标识，但不在源码里硬编码）。
///
/// 由构建参数注入；CI 从仓库 Secret `NEKO_CLIENT_ID` 取，避免明文出现在仓库与日志。
const String kNekoClientId = String.fromEnvironment('NEKO_CLIENT_ID');

/// 本源是否已具备自有客户端身份。
bool get nekoClientIdentityConfigured => kNekoClientId.isNotEmpty;
