/// 流媒体共享类型（对齐 shared/types/streaming.ts）。
library;

import 'streaming_errors.dart';
import 'streaming_session.dart';

/// 支持的流媒体服务器类型。
enum StreamingServerType {
  subsonic,
  navidrome,
  opensubsonic,
  airsonic,
  gonic,
  lms,
  jellyfin,
  emby;

  /// 按名称解析；未知返回 null。
  static StreamingServerType? tryParse(String? raw) {
    for (final t in StreamingServerType.values) {
      if (t.name == raw) return t;
    }
    return null;
  }
}

/// 服务器配置（可 JSON 序列化，用于本地持久化）。
///
/// 地址以「主机 + 端口」分开存储：[host]（localhost / 局域网 IP / 真实
/// IPv4 / IPv6 / 域名，不含 scheme 与端口）+ [port]。开启 [isArchoeraServer]
/// 时连接本机 ArchoeraMusic 内置 Subsonic 服务端，端口由运行时协商，
/// 无需填写端口。
class StreamingServerConfig {
  StreamingServerConfig({
    required this.id,
    required this.name,
    required this.type,
    required this.host,
    required this.username,
    required this.password,
    this.port,
    this.isArchoeraServer = false,
    this.useHttps = false,
    this.accessToken,
    this.userId,
    this.lastConnected,
  });

  /// crypto.randomUUID() 风格 id。
  final String id;
  final String name;
  final StreamingServerType type;

  /// 服务器主机：localhost / 局域网 IP / 真实 IPv4 / IPv6 / 域名。
  /// 不含 scheme 与端口；IPv6 可带 `[ ]` 也可裸写（解析时自动补括号）。
  final String host;

  /// 端口。为 null 时用协议默认端口（http 80 / https 443）；
  /// [isArchoeraServer] 时忽略（由运行时协商）。
  final int? port;

  /// 是否连接本机 ArchoeraMusic 内置 Subsonic 服务端。
  /// 开启后连接地址为主机 + 协商端口（服务端 started 事件回传），
  /// 服务端不可用（未运行/未注册）时连接报网络错误。
  final bool isArchoeraServer;

  /// 是否使用 https（仅外部服务端有意义；本机内置服务端恒为 http）。
  final bool useHttps;

  final String username;

  /// 明文密码。
  final String password;

  /// Jellyfin/Emby 鉴权后回填。
  final String? accessToken;

  /// Jellyfin/Emby 鉴权后回填的用户 ID。
  final String? userId;

  /// 最后一次连接成功的时间戳（ms）。
  final int? lastConnected;

  StreamingServerConfig copyWith({
    String? name,
    StreamingServerType? type,
    String? host,
    int? port,
    bool? isArchoeraServer,
    bool? useHttps,
    String? username,
    String? password,
    String? accessToken,
    String? userId,
    int? lastConnected,
  }) {
    return StreamingServerConfig(
      id: id,
      name: name ?? this.name,
      type: type ?? this.type,
      host: host ?? this.host,
      port: port ?? this.port,
      isArchoeraServer: isArchoeraServer ?? this.isArchoeraServer,
      useHttps: useHttps ?? this.useHttps,
      username: username ?? this.username,
      password: password ?? this.password,
      accessToken: accessToken ?? this.accessToken,
      userId: userId ?? this.userId,
      lastConnected: lastConnected ?? this.lastConnected,
    );
  }

  /// 本机 ArchoeraMusic 内置 Subsonic 服务端配置：仅需填写主机
  /// （localhost / 局域网 IP / IPv6 / 域名均可），端口由运行时自动协商。
  factory StreamingServerConfig.ownSubsonic({
    required String id,
    required String host,
    required String username,
    required String password,
    String name = '本机 ArchoeraMusic',
  }) {
    return StreamingServerConfig(
      id: id,
      name: name,
      type: StreamingServerType.subsonic,
      host: host,
      isArchoeraServer: true,
      username: username,
      password: password,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'host': host,
        if (port != null) 'port': port,
        if (isArchoeraServer) 'isArchoeraServer': true,
        if (useHttps) 'useHttps': true,
        'username': username,
        'password': password,
        if (accessToken != null) 'accessToken': accessToken,
        if (userId != null) 'userId': userId,
        if (lastConnected != null) 'lastConnected': lastConnected,
      };

  factory StreamingServerConfig.fromJson(Map<String, dynamic> json) {
    final host = json['host']?.toString();
    int? port = (json['port'] as num?)?.toInt();
    var useHttps = json['useHttps'] == true;
    var resolvedHost = (host == null || host.isEmpty) ? '' : host;
    if ((host == null || host.isEmpty) && json['url'] != null) {
      // 旧格式迁移：从完整 url 拆出 host / port / scheme
      final legacy = Uri.tryParse(json['url'].toString());
      if (legacy != null) {
        resolvedHost = legacy.host;
        if (legacy.hasPort) port = legacy.port;
        useHttps = legacy.scheme == 'https';
      }
    }
    return StreamingServerConfig(
      id: json['id']?.toString() ?? newUuid(),
      name: json['name']?.toString() ?? '',
      type: StreamingServerType.tryParse(json['type']?.toString()) ??
          StreamingServerType.subsonic,
      host: resolvedHost,
      port: port,
      isArchoeraServer: json['isArchoeraServer'] == true,
      useHttps: useHttps,
      username: json['username']?.toString() ?? '',
      password: json['password']?.toString() ?? '',
      accessToken: json['accessToken']?.toString(),
      userId: json['userId']?.toString(),
      lastConnected: (json['lastConnected'] as num?)?.toInt(),
    );
  }
}

/// 添加/编辑表单提交时的 payload。
class StreamingServerInput {
  const StreamingServerInput({
    required this.name,
    required this.type,
    required this.host,
    required this.username,
    required this.password,
    this.port,
    this.isArchoeraServer = false,
    this.useHttps = false,
  });

  final String name;
  final StreamingServerType type;
  final String host;
  final int? port;
  final bool isArchoeraServer;
  final bool useHttps;
  final String username;
  final String password;
}

/// 连通性测试结果。
class StreamingPingResult {
  const StreamingPingResult({
    required this.ok,
    this.version,
    this.error,
    this.code,
  });

  final bool ok;

  /// 服务器版本号。
  final String? version;

  /// 失败描述。
  final String? error;

  /// 失败归类（仅 ok=false 时有意义）。
  final StreamingErrorCode? code;
}

/// Jellyfin/Emby 登录返回。
class StreamingAuthResult {
  const StreamingAuthResult({
    required this.accessToken,
    required this.userId,
  });

  final String accessToken;
  final String userId;
}

/// 列表请求通用参数。
class StreamingListParams {
  const StreamingListParams({this.offset, this.limit});

  final int? offset;
  final int? limit;
}
