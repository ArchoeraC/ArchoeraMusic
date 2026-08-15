import '../services/history/history_store.dart';
import 'app_prefs.dart';

// ── 播放历史键（history. 前缀）────────────────────────────────
const historyEnabledKey = 'history.enabled';
const historyLimitKey = 'history.limit';

/// 播放历史偏好：记录开关 + 条数上限（null = 不限制）。
///
/// 上限落盘语义：>0 = 限额条数；0 = 不限制（见 [historyLimit] 的空值
/// 转换，对齐歌词/封面缓存「0 = 无上限」约定）；缺失回退默认 500。
extension HistoryPrefs on AppPrefs {
  /// 是否记录播放历史（默认开；关闭 = 暂停记录，已有数据保留）。
  bool get historyEnabled => data[historyEnabledKey] as bool? ?? true;

  /// 历史条数上限（null = 不限制；缺失回退默认 [HistoryStore.defaultLimit]）。
  int? get historyLimit {
    final v = data[historyLimitKey];
    if (v is int && v > 0) return v;
    if (v is int && v == 0) return null; // 显式「不限制」
    return HistoryStore.defaultLimit;
  }

  AppPrefs copyWithHistory({bool? enabled, int? limit}) {
    final next = {...data};
    if (enabled != null) next[historyEnabledKey] = enabled;
    if (limit != null) {
      // null（不限制）→ 0；有限额 → 限额条数
      next[historyLimitKey] = limit <= 0 ? 0 : limit;
    }
    return AppPrefs(initialData: next);
  }
}
