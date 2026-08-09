/// 通用 LRU 内存缓存——对齐 apis/common/cache.ts。
///
/// 基于 Map 的 LRU 淘汰（命中时 re-insert 到末尾），TTL 默认 2 分钟。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

class _Entry<V> {
  _Entry(this.value, this.expireAt);

  final V value;
  final int expireAt;
}

class LruCache<V> {
  LruCache({this.ttl = 2 * 60 * 1000, this.maxEntries = 200, this.shouldCache});

  final int ttl;
  final int maxEntries;
  final bool Function(V value)? shouldCache;

  final _store = <String, _Entry<V>>{};

  /// 构造缓存 key：`name|md5(params)` 8 位前缀
  static String key(String name, Map<String, dynamic>? params) {
    final hash = _md5Prefix(params);
    return '$name|$hash';
  }

  V? get(String key) {
    final hit = _store[key];
    if (hit == null) return null;
    if (hit.expireAt <= DateTime.now().millisecondsSinceEpoch) {
      _store.remove(key);
      return null;
    }
    // LRU：命中时重新插入到末尾
    _store.remove(key);
    _store[key] = hit;
    return hit.value;
  }

  void set(String key, V value, [int? ttlMs]) {
    if (shouldCache != null && !shouldCache!(value)) return;
    if (_store.length >= maxEntries) {
      final oldest = _store.keys.firstOrNull;
      if (oldest != null) _store.remove(oldest);
    }
    _store[key] = _Entry(
      value,
      DateTime.now().millisecondsSinceEpoch + (ttlMs ?? ttl),
    );
  }

  void clear() => _store.clear();

  int get size => _store.length;
}

String _md5Prefix(Map<String, dynamic>? params) {
  final json = params == null ? 'null' : _stableJson(params);
  return md5.convert(utf8.encode(json)).toString().substring(0, 8);
}

/// Map 序列化时保持 key 排序，保证相同内容产生相同缓存 key
String _stableJson(Map<String, dynamic> map) {
  final sorted = <String, dynamic>{
    for (final k in (map.keys.toList()..sort())) k: map[k],
  };
  return _jsonEncode(sorted);
}

String _jsonEncode(Object? value) {
  if (value is Map) {
    final entries = value.entries.toList();
    entries.sort((a, b) => '${a.key}'.compareTo('${b.key}'));
    final inner = entries.map((e) => '"${e.key}":${_jsonEncode(e.value)}').join(',');
    return '{$inner}';
  }
  if (value is List) {
    return '[${value.map(_jsonEncode).join(',')}]';
  }
  if (value is String) return '"$value"';
  if (value == null) return 'null';
  return '$value';
}
