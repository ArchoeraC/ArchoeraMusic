import 'app_prefs.dart';

// ── 搜索键（search. 前缀）──────────────────────────────────────
const searchHistoryKey = 'search.history';

/// 搜索历史条数上限（对齐原项目 MAX_SEARCH_HISTORY=20，最新在前）。
const int maxSearchHistory = 20;

/// 搜索偏好：搜索历史（关键词列表，最新在前、去重）。
extension SearchPrefs on AppPrefs {
  /// 搜索历史（最新在前；非法值回退空）。
  List<String> get searchHistory {
    final v = data[searchHistoryKey];
    if (v is List) return v.whereType<String>().toList();
    return const [];
  }

  AppPrefs copyWithSearchHistory(List<String> history) =>
      AppPrefs(initialData: {...data, searchHistoryKey: history});
}
