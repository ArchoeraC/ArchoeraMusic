// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'app_prefs.dart';

// ── 搜索键（search. 前缀）──────────────────────────────────────
const searchHistoryKey = 'search.history';

/// 本地曲库搜索索引（总开关）键：**默认关**。
const enableLocalSearchIndexKey = 'search.index.enabled';

/// `.lrc` 侧车歌词索引键：**默认关**（仅总开关开启时才有意义）。
const indexLrcKey = 'search.index.lrc';

/// 搜索历史条数上限（对齐原项目 MAX_SEARCH_HISTORY=20，最新在前）。
const int maxSearchHistory = 20;

/// 搜索偏好：搜索历史（关键词列表，最新在前、去重）+ 本地曲库搜索索引开关。
extension SearchPrefs on AppPrefs {
  /// 搜索历史（最新在前；非法值回退空）。
  List<String> get searchHistory {
    final v = data[searchHistoryKey];
    if (v is List) return v.whereType<String>().toList();
    return const [];
  }

  AppPrefs copyWithSearchHistory(List<String> history) =>
      AppPrefs(initialData: {...data, searchHistoryKey: history});

  /// 本地曲库搜索索引**总开关**（默认关）：关闭时不加载索引器 /
  /// 不建库 / 不接管搜索，回退现有 `LIKE`（设计文档 §2.4）。
  /// 非法值（非布尔）一律回退默认关。
  bool get enableLocalSearchIndex => data[enableLocalSearchIndexKey] == true;

  /// 是否索引 `.lrc` 侧车歌词（默认关；仅总开关开启时生效，设计文档 §4.4）。
  /// 非法值（非布尔）一律回退默认关。
  bool get indexLrc => data[indexLrcKey] == true;

  /// 写入本地搜索索引开关（总开关 / `.lrc` 子开关）。
  AppPrefs copyWithSearchIndex({bool? enabled, bool? indexLrc}) => AppPrefs(
    initialData: {
      ...data,
      enableLocalSearchIndexKey: ?enabled,
      indexLrcKey: ?indexLrc,
    },
  );
}
