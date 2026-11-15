// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Songloft 客户端会话：FFI 句柄 + 请求/事件轮询 + 凭据回写。
///
/// 现有 `StreamingClient(cfg)` 无状态；Songloft 的会话带 token 与连接池，
/// 不能每次构造都重新登录，因此按 `serverId` 共享（见 docs/songloft-client.md §4.5）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../../stores/data_dir.dart';
import '../streaming_errors.dart';
import '../streaming_store.dart';
import '../streaming_types.dart';
import 'songloft_bindings.dart';

/// 测试注入：非空时替代 [resolveDataDir] 下的封面缓存目录。
String? songloftCoverCacheDirOverride;

/// 封面缓存根目录（Go 负责写入，Dart 负责拼路径与预取）。
String get songloftCoverCacheDir =>
    songloftCoverCacheDirOverride ??
    '${resolveDataDir()}/cache/songloft_covers';

/// 单个 Songloft 服务器会话。
class SongloftSession {
  SongloftSession._(this.serverId, this._cfg, this._bindings, this._handle);

  final String serverId;
  final StreamingServerConfig _cfg;
  final SongloftBindings _bindings;
  final int _handle;

  /// 测试注入：置 false 时不把 token 回写 vault（避免测试环境启动 vault 进程）。
  static bool persistTokens = true;

  static final Map<String, SongloftSession> _sessions = {};
  static final Map<String, Future<SongloftSession>> _opening = {};

  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  final Completer<String> _ready = Completer<String>();
  Timer? _poll;
  int _seq = 0;
  bool _closed = false;
  String _version = '';
  String _accessToken = '';

  /// 按 serverId 取得（或创建）会话；并发调用只打开一次。
  static Future<SongloftSession> ensure(StreamingServerConfig cfg) {
    final existing = _sessions[cfg.id];
    if (existing != null && !existing._closed) {
      return Future.value(existing);
    }
    return _opening.putIfAbsent(cfg.id, () {
      final f = _open(cfg);
      // 注意：回调必须返回 void——直接 `=> map.remove(...)` 会把 map 中
      // 这个 future 自身返回给 whenComplete，形成自等待、永远不完成。
      return f.whenComplete(() {
        _opening.remove(cfg.id);
      });
    });
  }

  /// 关闭某服务器会话（断开 / 删除 / 更新配置时调用）。
  static void closeServer(String serverId) {
    _sessions.remove(serverId)?.dispose();
    // 打开中的会话：就绪后立即关闭，避免泄漏。
    final opening = _opening.remove(serverId);
    opening?.then((s) => s.dispose(), onError: (_) {});
  }

  /// 关闭全部会话（安全销毁流程）。
  static void closeAll() {
    for (final s in _sessions.values) {
      s.dispose();
    }
    _sessions.clear();
    for (final f in _opening.values) {
      f.then((s) => s.dispose(), onError: (_) {});
    }
    _opening.clear();
  }

  static Future<SongloftSession> _open(StreamingServerConfig cfg) async {
    await StreamingStore.loadSecret(cfg.id);
    final sec = StreamingStore.cachedSecret(cfg.id) ?? const <String, String>{};
    final password = cfg.password.isNotEmpty
        ? cfg.password
        : (sec['password'] ?? '');
    final config = <String, Object?>{
      'serverId': cfg.id,
      'scheme': cfg.useHttps ? 'https' : 'http',
      'host': cfg.host,
      'port': cfg.port ?? cfg.type.defaultPort,
      'username': cfg.username,
      'password': password,
      'accessToken': sec['accessToken'] ?? cfg.accessToken ?? '',
      'refreshToken': sec['refreshToken'] ?? '',
      'expiresAt': int.tryParse(sec['tokenExpiresAt'] ?? '') ?? 0,
      'coverCacheDir': songloftCoverCacheDir,
      'requestTimeoutMs': 30000,
    };
    final bindings = SongloftBindings.instance;
    final ptr = jsonEncode(config).toNativeUtf8();
    final int handle;
    try {
      handle = bindings.open(ptr);
    } finally {
      calloc.free(ptr);
    }
    if (handle == 0) {
      throw StreamingError('Songloft 会话创建失败（请检查服务器地址）');
    }
    final session = SongloftSession._(cfg.id, cfg, bindings, handle)
      .._accessToken = config['accessToken'] as String? ?? '';
    session._ensureTimer();
    try {
      // 就绪（version + 登录）后才放入共享表：避免其它调用在 token 尚未
      // 就绪时拿到会话并发请求。
      await session._ready.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      session.dispose();
      rethrow;
    }
    if (session._closed) {
      session.dispose();
      throw StreamingError('Songloft 会话已关闭');
    }
    _sessions[cfg.id] = session;
    return session;
  }

  String get version => _version;

  String get baseUrl {
    final scheme = _cfg.useHttps ? 'https' : 'http';
    return Uri(
      scheme: scheme,
      host: _cfg.host,
      port: _cfg.port ?? _cfg.type.defaultPort,
    ).toString();
  }

  String get coverCacheDir => configCoverDir;

  String get configCoverDir =>
      '$songloftCoverCacheDir/${_cfg.id}';

  /// 封面缓存文件路径（Go `getCover` 写入同一路径）。
  String coverPath(String kind, int id) => '$configCoverDir/$kind-$id.img';

  /// 封面直链（缓存文件尚未生成时的回退；token 走 query，与 Subsonic 一致）。
  String coverUrl(String kind, int id) {
    final api = kind == 'playlist' ? 'playlists' : 'songs';
    final token = Uri.encodeQueryComponent(_accessToken);
    return '$baseUrl/api/v1/$api/$id/cover?access_token=$token';
  }

  /// 发起异步请求；结果由轮询事件按 id 回填。
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    if (_closed) {
      return Future.error(StreamingError('Songloft 会话已关闭'));
    }
    final id = '${++_seq}';
    final request = jsonEncode({'id': id, 'method': method, 'params': params});
    final ptr = request.toNativeUtf8();
    try {
      final rc = _bindings.call(_handle, ptr);
      if (rc != 0) {
        throw StreamingError('Songloft 请求入队失败（$rc）');
      }
    } finally {
      calloc.free(ptr);
    }
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _ensureTimer();
    return completer.future.timeout(
      const Duration(seconds: 40),
      onTimeout: () {
        _pending.remove(id);
        throw StreamingTimeoutError('Songloft 请求超时');
      },
    );
  }

  void _ensureTimer() {
    _poll ??= Timer.periodic(const Duration(milliseconds: 20), (_) => _drain());
  }

  void _drain() {
    while (true) {
      final ev = _takeEvent();
      if (ev == null) break;
      _onEvent(ev);
    }
    if (_pending.isEmpty && _ready.isCompleted) {
      _poll?.cancel();
      _poll = null;
    }
  }

  Map<String, dynamic>? _takeEvent() {
    final len = calloc<Int32>();
    try {
      final ptr = _bindings.takeEvent(_handle, len);
      if (ptr == nullptr) return null;
      try {
        if (len.value <= 0) return null;
        final text = utf8.decode(ptr.cast<Uint8>().asTypedList(len.value));
        final decoded = jsonDecode(text);
        return decoded is Map<String, dynamic> ? decoded : null;
      } finally {
        _bindings.free(ptr);
      }
    } finally {
      calloc.free(len);
    }
  }

  void _onEvent(Map<String, dynamic> ev) {
    switch (ev['type']?.toString() ?? '') {
      case 'ready':
        _version = ev['version']?.toString() ?? '';
        if (!_ready.isCompleted) _ready.complete(_version);
      case 'error':
        final err = StreamingError(
          ev['message']?.toString() ?? 'Songloft 连接失败',
        );
        if (!_ready.isCompleted) _ready.completeError(err);
        _failPending(err);
      case 'token':
        _accessToken = ev['accessToken']?.toString() ?? _accessToken;
        if (persistTokens) {
          StreamingStore.saveSecret(
            serverId,
            accessToken: _accessToken,
            refreshToken: ev['refreshToken']?.toString(),
            tokenExpiresAt: (ev['expiresAt'] as num?)?.toInt(),
          );
        }
      case 'result':
        final id = ev['id']?.toString() ?? '';
        final completer = _pending.remove(id);
        if (completer == null) return;
        if (ev['ok'] == true) {
          final data = ev['data'];
          completer.complete(
            data is Map<String, dynamic> ? data : <String, dynamic>{},
          );
        } else {
          completer.completeError(_mapError(ev['error']));
        }
    }
  }

  Object _mapError(Object? raw) {
    if (raw is Map) {
      final code = raw['code']?.toString() ?? 'protocol';
      final message = raw['message']?.toString() ?? '';
      switch (code) {
        case 'auth':
          return StreamingAuthError(message);
        case 'timeout':
          return StreamingTimeoutError(message);
        case 'network':
          return StreamingNetworkError(message);
        case 'not-found':
          return StreamingHttpError(404, message);
        default:
          return StreamingProtocolError(message);
      }
    }
    return StreamingProtocolError(raw?.toString() ?? '未知错误');
  }

  void _failPending(Object error) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(error);
    }
    _pending.clear();
  }

  /// 关闭会话（幂等）。
  void dispose() {
    if (_closed) return;
    _closed = true;
    _poll?.cancel();
    _poll = null;
    _bindings.close(_handle);
    final err = StreamingError('Songloft 会话已断开');
    _failPending(err);
    if (!_ready.isCompleted) _ready.completeError(err);
  }
}
