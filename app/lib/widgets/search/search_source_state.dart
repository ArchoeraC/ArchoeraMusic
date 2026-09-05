/// 聚合搜索「各源独立」的纯逻辑（供 search_page 使用，可离线单测）。
library;

import '../../services/netease/netease_api.dart' show SearchResult;

/// 单源一次尝试结果：成功携带结果，失败携带错误，互不阻塞。
class SourceAttempt<T> {
  const SourceAttempt.ok(this.source, this.result) : error = null;

  const SourceAttempt.fail(this.source, this.error) : result = null;

  final String source;
  final SearchResult<T>? result;
  final Object? error;

  bool get ok => result != null;
}

/// 并行请求多个来源，**各源独立 try/catch**：任一源失败只标记该源，
/// 其余来源照常返回（解决聚合整体 `Future.wait` 一源失败全盘失败的问题）。
Future<List<SourceAttempt<T>>> fetchSourcesIndependently<T>(
  List<String> sources,
  Future<SearchResult<T>> Function(String source) run,
) {
  return Future.wait(
    sources.map((source) async {
      try {
        return SourceAttempt<T>.ok(source, await run(source));
      } catch (err) {
        return SourceAttempt<T>.fail(source, err);
      }
    }),
  );
}

/// 失败后的防抖 / 退避闸门：来源失败后的一段时间内不自动也不允许反复手动
/// 重试，避免连打把平台风控阈值刷得更高（QQ 实测风险内码 2001）。
class SearchSourceCooldown {
  SearchSourceCooldown({this.cooldown = const Duration(seconds: 20)});

  /// 冷却时长。
  final Duration cooldown;

  final Map<String, DateTime> _failedAt = {};

  /// 记录一次来源失败。
  void markFailed(String source, {DateTime? now}) {
    _failedAt[source] = now ?? DateTime.now();
  }

  /// 清除冷却（来源重试成功后调用）。
  void clear(String source) => _failedAt.remove(source);

  /// 距最近失败经过的时间。
  Duration sinceFailure(String source, {DateTime? now}) {
    final at = _failedAt[source];
    if (at == null) return cooldown;
    final d = (now ?? DateTime.now()).difference(at);
    return d.isNegative ? Duration.zero : d;
  }

  /// 是否仍在冷却（此时应拒绝自动/手动重试）。
  bool cooling(String source, {DateTime? now}) =>
      sinceFailure(source, now: now) < cooldown;

  /// 剩余冷却时长（≤0 为可重试）。
  Duration remaining(String source, {DateTime? now}) {
    final left = cooldown - sinceFailure(source, now: now);
    return left.isNegative ? Duration.zero : left;
  }
}
