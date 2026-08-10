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
