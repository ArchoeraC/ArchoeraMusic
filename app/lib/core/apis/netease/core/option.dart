/// 请求 options 工厂——对齐 apis/netease/core/option.ts。
///
/// 从调用方 query 中抽取 crypto / cookie / ua / realIP / e_r / domain 等，
/// 拼成 createRequest 的第三参数。
library;

import 'request.dart';

/// 调用方传入的可选参数
class NmQuery {
  NmQuery({
    this.crypto,
    this.cookie,
    this.ua,
    this.realIP,
    this.ip,
    this.eR,
    this.domain,
    this.checkToken = false,
    this.extra = const {},
  });

  /// 加密方式
  String? crypto;
  /// 预注入 cookie，可为字符串或对象
  Object? cookie;
  /// 自定义 User-Agent
  String? ua;
  /// 真实 IP（X-Real-IP / X-Forwarded-For）
  String? realIP;
  String? ip;
  /// 是否让服务端加密响应体（仅 weapi/eapi 有效）
  bool? eR;
  /// 自定义 Referer/域名覆盖
  String? domain;
  /// 强制附加 anti-cheat token（暂未启用）
  bool checkToken;
  /// 业务参数（模块自行展开）
  Map<String, dynamic> extra;
}

/// 从 Map 构造 [NmQuery]（模块层 `(query, request)` 的 query 是动态 Map）
NmQuery nmQueryFrom(Map<String, dynamic> map) => NmQuery(
      crypto: map['crypto'] as String?,
      cookie: map['cookie'],
      ua: map['ua'] as String?,
      realIP: map['realIP'] as String?,
      ip: map['ip'] as String?,
      eR: map['e_r'] as bool?,
      domain: map['domain'] as String?,
      checkToken: (map['checkToken'] as bool?) ?? false,
      extra: map,
    );

/// 创建请求 options
NeteaseRequestOptions nmCreateOption(Map<String, dynamic> query,
    [String crypto = '']) {
  return NeteaseRequestOptions(
    crypto: (query['crypto'] as String?) ?? crypto,
    cookie: query['cookie'],
    ua: (query['ua'] as String?) ?? '',
    realIP: query['realIP'] as String?,
    ip: query['ip'] as String?,
    eR: query['e_r'] as bool?,
    domain: (query['domain'] as String?) ?? '',
    checkToken: (query['checkToken'] as bool?) ?? false,
  );
}
