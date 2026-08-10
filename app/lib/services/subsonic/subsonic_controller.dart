/// Subsonic 服务端控制器（发送方）：create/pollEvent/歌词注入/凭据加解密。
///
/// 对应 Go 库 archoera_subsonic_* 导出。典型用法：
///   final c = SubsonicController(config: SubsonicConfig(...));
///   c.start();                          // 异步启动 http server（库内 goroutine）
///   while (true) { final ev = c.pollEvent(); if (ev != null) ...; }
///   c.dispose();
library;

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'subsonic_bindings.dart';

/// 服务端配置（映射 Go 侧 config.Config JSON）。
class SubsonicConfig {
  SubsonicConfig({
    this.dbPath = '',
    this.musicDir = '',
    this.dataDir = '',
    this.secretKey = '',
    this.addr = '0.0.0.0:0',
    this.transcoder = '',
  });

  /// library.db 路径（空 → Go 侧默认 dataDir/database/library.db）
  final String dbPath;

  /// 音乐根目录
  final String musicDir;

  /// 数据目录（covers 缓存、secret.key 等）
  final String dataDir;

  /// 凭据加密密钥（64 位 hex，经 create 注入，Go 侧 LoadKey 优先读取）
  final String secretKey;

  /// 监听地址（对外提供 Subsonic API；默认 `0.0.0.0:0` = 全接口 +
  /// 系统分配空闲端口，实际地址经 started 事件回传。需限制访问面时
  /// 可改为 `127.0.0.1:0` 等）
  final String addr;

  /// 转码器动态库路径（libarchoera_transcoder.so；空 → Go 侧 dlopen 按构建目录查找）
  final String transcoder;

  Map<String, Object> toJson() => {
        if (dbPath.isNotEmpty) 'dbPath': dbPath,
        if (musicDir.isNotEmpty) 'musicDir': musicDir,
        if (dataDir.isNotEmpty) 'dataDir': dataDir,
        if (secretKey.isNotEmpty) 'secretKey': secretKey,
        if (addr.isNotEmpty) 'addr': addr,
        if (transcoder.isNotEmpty) 'transcoder': transcoder,
      };
}

/// 服务端事件（对应 Go 侧事件 JSON）。
sealed class SubsonicServerEvent {}

/// started：服务已就绪，含监听地址与库路径。
class SubsonicStarted extends SubsonicServerEvent {
  SubsonicStarted({required this.addr, required this.dbPath});
  final String addr;
  final String dbPath;
}

/// error：启动/运行错误。
class SubsonicServerError extends SubsonicServerEvent {
  SubsonicServerError(this.message);
  final String message;
}

/// lyric-request：服务端请求宿主查在线歌词。
/// 宿主查完后须调用 controller.respondLyric(requestId, resultJson)。
class SubsonicLyricRequest extends SubsonicServerEvent {
  SubsonicLyricRequest({
    required this.requestId,
    required this.songId,
    required this.title,
    required this.artist,
  });
  final int requestId;
  final String songId;
  final String title;
  final String artist;
}

/// scan-request：外部请求触发曲库扫描（宿主接入 scanner）。
class SubsonicScanRequest extends SubsonicServerEvent {
  SubsonicScanRequest(this.fullScan);
  final bool fullScan;
}

/// Subsonic 服务端控制器（单实例语义）。
class SubsonicController {
  SubsonicController._(this._h, this._bindings);

  final int _h;
  final SubsonicBindings _bindings;
  bool _disposed = false;

  /// 创建服务（create 立即返回；服务在库内 goroutine 异步启动，
  /// 就绪/错误经 pollEvent 上报）。
  factory SubsonicController(SubsonicConfig config) {
    final bindings = SubsonicBindings.instance;
    final jsonStr = jsonEncode(config.toJson());
    final configPtr = jsonStr.toNativeUtf8();
    try {
      final h = bindings.create(configPtr);
      if (h == 0) {
        throw StateError('archoera_subsonic_create 失败（详见 stderr）');
      }
      return SubsonicController._(h, bindings);
    } finally {
      calloc.free(configPtr);
    }
  }

  /// 取一条事件；无事件返回 null。事件类型见 [SubsonicServerEvent]。
  /// lyric-request 需宿主查询在线歌词后经 [respondLyric] 回填。
  SubsonicServerEvent? pollEvent() {
    _checkNotDisposed();
    const bufLen = 16384;
    final buf = calloc<Uint8>(bufLen);
    try {
      final n = _bindings.pollEvent(_h, buf, bufLen);
      if (n <= 0) return null;
      final bytes = buf.asTypedList(n);
      final text = utf8.decode(bytes, allowMalformed: true);
      return _parseEvent(text);
    } finally {
      calloc.free(buf);
    }
  }

  /// 提交在线歌词查询结果。
  /// [resultJson] 结构：`{"main": "...", "translation": "...", "romaji": "..."}`
  ///（与 endpoints.injectLyricResp 对齐；main 为空视为无歌词）。
  void respondLyric(int requestId, String resultJson) {
    _checkNotDisposed();
    final resultPtr = resultJson.toNativeUtf8();
    try {
      _bindings.lyricResponse(_h, requestId, resultPtr);
    } finally {
      calloc.free(resultPtr);
    }
  }

  /// 加密明文（返回 enc:v1:iv:tag:ct 密文；失败返回 null）。
  String? encrypt(String plain) {
    _checkNotDisposed();
    return _crypt(_bindings.encrypt, plain);
  }

  /// 解密密文（非加密格式原样返回；失败返回 null）。
  String? decrypt(String cipher) {
    _checkNotDisposed();
    return _crypt(_bindings.decrypt, cipher);
  }

  String? _crypt(
      int Function(int handle, Pointer<Utf8> input, Pointer<Uint8> buf, int bufLen) fn,
      String input) {
    const bufLen = 4096;
    final inputPtr = input.toNativeUtf8();
    final buf = calloc<Uint8>(bufLen);
    try {
      final n = fn(_h, inputPtr, buf, bufLen);
      if (n <= 0) return null;
      return utf8.decode(buf.asTypedList(n), allowMalformed: true);
    } finally {
      calloc.free(inputPtr);
      calloc.free(buf);
    }
  }

  /// 销毁：Shutdown http server + 释放资源（幂等）。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindings.destroy(_h);
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('SubsonicController 已销毁');
  }

  static SubsonicServerEvent _parseEvent(String text) {
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      switch (json['type']) {
        case 'started':
          return SubsonicStarted(
            addr: json['addr']?.toString() ?? '',
            dbPath: json['dbPath']?.toString() ?? '',
          );
        case 'error':
          return SubsonicServerError(json['message']?.toString() ?? 'unknown');
        case 'lyric-request':
          return SubsonicLyricRequest(
            requestId: (json['id'] as num).toInt(),
            songId: json['songId']?.toString() ?? '',
            title: json['title']?.toString() ?? '',
            artist: json['artist']?.toString() ?? '',
          );
        case 'scan-request':
          return SubsonicScanRequest(json['fullScan'] as bool? ?? false);
        default:
          return SubsonicServerError('未知事件: $text');
      }
    } catch (_) {
      return SubsonicServerError('事件解析失败: $text');
    }
  }
}
