// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Netease API 模块函数签名——对齐 apis/netease/core/types.ts。
///
/// 每个 module 都是 `(query, request) => Promise<RequestResponse>`。
library;

import 'request.dart';

/// 请求函数签名（createRequest）
typedef NeteaseRequestFn =
    Future<NeteaseResponse> Function(
      String uri,
      Map<String, dynamic> data,
      NeteaseRequestOptions options,
    );

/// 模块函数签名
typedef NeteaseModule =
    Future<NeteaseResponse> Function(
      Map<String, dynamic> query,
      NeteaseRequestFn request,
    );
