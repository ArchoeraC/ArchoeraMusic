// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// KG 模块注册表——对齐 apis/kugou/modules/index.ts。
library;

import '../core/types.dart';

import 'lyric.dart';
import 'search.dart';

/// 模块注册表：key 与 TS index.ts 完全一致
final Map<String, KgModule> kgModules = {
  'search': kgSearch,
  'lyric': kgLyric,
};
