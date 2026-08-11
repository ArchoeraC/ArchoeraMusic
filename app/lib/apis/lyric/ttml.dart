/// AMLL TTML DB 抓取（对齐 apis/common/lyric/ttml.ts）。
///
/// - 用户配置的 URL 模板含 %p（平台目录）和 %s（id），代码替换
///   - NCM → "ncm-lyrics"
///   - QM  → "qq-lyrics"（mid 或数字 id 都可能命中，由调用方传入候选）
/// - 8s 超时，dart:io HttpClient
/// - inflight Map 做并发去重：同 (platform, id) 的并发抓取共享同一个 Future，
///   后端 prefetchTTML 提前发出的请求和渲染端 fetchTTMLOverlay 的请求会合并
/// - 缓存策略见 LyricTtmlCacheStore：正缓存永久 / 负缓存 72h
library;

import 'dart:convert';
import 'dart:io';

import '../logger.dart';
import '../runtime.dart';

typedef TtmlPlatform = String; // 'netease' | 'qqmusic'

const int _timeoutMs = 8000;

final Map<String, Future<String?>> _inflight = {};

/// 真正发起一次抓取，处理缓存读写、URL 拼装、错误分类
Future<String?> _doFetch(String platform, String id) async {
  // 开关关闭时短路，让预热调用零成本
  if (getRuntime().getSetting('lyric.enableOnlineTTMLLyric') != true) return null;

  final cached = getRuntime().lyricTtmlCache.get(platform, id);
  if (cached != lyricTtmlMiss) return cached as String?;

  final tmpl = getRuntime().getSetting('lyric.amllDbServer');
  if (tmpl is! String || !tmpl.contains('%p') || !tmpl.contains('%s')) return null;

  final path = platform == 'netease' ? 'ncm-lyrics' : 'qq-lyrics';
  final url = tmpl.replaceAll('%p', path).replaceAll('%s', Uri.encodeComponent(id));

  final client = HttpClient()..connectionTimeout = const Duration(seconds: _timeoutMs);
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close().timeout(const Duration(seconds: _timeoutMs));
    if (res.statusCode == 200) {
      final content = await res.transform(utf8.decoder).join();
      // 接口偶尔会返回 200 但 body 为空，按负缓存处理
      if (content.trim().isEmpty) {
        getRuntime().lyricTtmlCache.set(platform, id, null);
        return null;
      }
      getRuntime().lyricTtmlCache.set(platform, id, content);
      return content;
    }
    if (res.statusCode == 404) {
      getRuntime().lyricTtmlCache.set(platform, id, null);
      return null;
    }
    // 其它状态码（5xx 等）不写缓存，下次重试
    coreLog.warn('[ttml] $platform:$id HTTP ${res.statusCode}');
    return null;
  } catch (err) {
    coreLog.warn('[ttml] $platform:$id fetch failed: $err');
    return null;
  } finally {
    client.close();
  }
}

/// 单 id 抓取 + inflight 去重，仅内部使用
Future<String?> _fetchOne(String platform, String id) {
  final key = '$platform:$id';
  final existing = _inflight[key];
  if (existing != null) return existing;
  final promise = _doFetch(platform, id).whenComplete(() => _inflight.remove(key));
  _inflight[key] = promise;
  return promise;
}

/// 依次尝试多个候选 id，命中即停。
/// - NCM 通常只传 [id]
/// - QM 传 [mid, id]：AMLL DB 里两种 key 都可能存在，逐一回落
/// 失败的 id 会被写入负缓存，后续重试零网络。
Future<String?> fetchTTML(String platform, List<String> ids) async {
  for (final id in ids) {
    if (id.isEmpty) continue;
    final result = await _fetchOne(platform, id);
    if (result != null) return result;
  }
  return null;
}

/// 预热抓取：在 id 已确定的最早瞬间发出 TTML 请求。
/// 渲染端后续的 fetchTTMLOverlay 调用会通过 inflight Map 复用同一个 Future。
void prefetchTTML(String platform, List<String> ids) {
  // ignore: unawaited_futures
  fetchTTML(platform, ids);
}
