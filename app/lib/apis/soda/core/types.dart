// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水模块函数签名（对齐 QQ/netease 的模块注册表范式）。
library;

/// 业务参数
typedef SodaParams = Map<String, dynamic>;

/// 模块函数签名
typedef SodaModule = Future<Object?> Function(SodaParams params);
