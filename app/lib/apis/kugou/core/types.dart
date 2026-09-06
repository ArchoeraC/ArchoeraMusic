// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// KG 模块函数签名——对齐 apis/kugou/core/types.ts。
library;

/// 业务参数
typedef KgParams = Map<String, dynamic>;

/// 模块函数签名
typedef KgModule = Future<Object?> Function(KgParams params);
