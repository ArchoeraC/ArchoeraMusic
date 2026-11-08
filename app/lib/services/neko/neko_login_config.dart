// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic 传统账号密码登录开关（**编译期默认关闭**）。
///
/// NekoMusic 服务端已下线邮箱密码登录链路（`/api/user/login` 等），
/// 新客户端统一走 NekoAuth OAuth。这里保留账号密码界面与调用代码，便于
/// 将来服务端恢复该能力时**无需改 UI** 即可重新启用：
///
/// ```bash
/// flutter build … --dart-define=NEKO_ENABLE_PASSWORD_LOGIN=true
/// ```
///
/// 用 getter 读取而不是直接 `const bool` 条件，避免分析器把 UI 代码判成
/// 不可达（dead_code）；实际取值仍是编译期常量，默认构建会被 tree-shake。
bool get nekoPasswordLoginEnabled =>
    const bool.fromEnvironment('NEKO_ENABLE_PASSWORD_LOGIN');
