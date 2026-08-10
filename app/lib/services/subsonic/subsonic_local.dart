/// 本机 ArchoeraMusic 内置 Subsonic 服务端（发送方）的运行时协商。
///
/// 客户端配置以「主机 + 端口」分开存储，开启 [StreamingServerConfig]
/// 的 `isArchoeraServer`（连接 ArchoeraMusic 服务端）后无需填写端口：
/// 服务端启动时绑定端口 0 由系统分配，实际端口经 started 事件回传，
/// 由服务端生命周期持有者调用 [SubsonicLocalServer.register] 注册，
/// 客户端连接时经 [resolvedServerBaseUrl] 换成真实端口。
///
/// 协商只替换端口、保留配置的主机，因此主机可以是 localhost、
/// 局域网 192.168.x.x、真实 IPv4、IPv6（含 `[ ]`）或域名。
///
/// 其他来源的服务端（Navidrome/Jellyfin 等）不开启该开关，使用手动端口。
library;

import '../streaming/streaming_types.dart';

/// 本机内置服务端运行时信息（由服务端生命周期持有者注册）。
class SubsonicLocalServer {
  SubsonicLocalServer._();

  /// 服务端实际监听地址（如 `0.0.0.0:44141`，来自 started 事件）。
  static String? addr;

  /// 实际端口（未注册或无端口时为 null）。
  static int? port;

  /// 注册服务端地址（started 事件到达时调用）；服务停止时传 null 注销。
  static void register(String? address) {
    addr = address;
    int? p;
    final u = Uri.tryParse('//${address ?? ''}');
    if (u != null && u.hasPort) p = u.port;
    port = p;
  }
}

/// host 转 URI 可用形式：IPv6 裸地址（含冒号）自动补 `[ ]`。
String serverHostForUri(String host) {
  if (host.startsWith('[')) return host;
  if (host.contains(':')) return '[$host]';
  return host;
}

/// 解析连接基础地址（不含尾斜杠）。
///
/// - [isArchoeraServer]：主机取配置 host，端口取本机服务端协商值；
///   协商不可用（服务端未运行/未注册）时回退默认端口，连接将报网络错误。
/// - 其他：`scheme://host:port`（port 为 null 用协议默认端口）。
String resolvedServerBaseUrl(StreamingServerConfig cfg) {
  final host = serverHostForUri(cfg.host);
  if (cfg.isArchoeraServer) {
    final p = SubsonicLocalServer.port;
    if (p != null) return 'http://$host:$p';
    return 'http://$host'; // 服务端不可用，连接时失败为网络错误
  }
  final scheme = cfg.useHttps ? 'https' : 'http';
  final port = cfg.port;
  if (port == null) return '$scheme://$host';
  return '$scheme://$host:$port';
}
