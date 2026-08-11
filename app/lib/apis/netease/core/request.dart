/// Netease API 请求层（Dart 直连全量移植）——对齐 apis/netease/core/request.ts。
///
/// 核心职责：根据加密方式（weapi / linuxapi / eapi / api / xeapi）构造 URL、
/// headers、form body，处理 cookie 合并、响应解密、状态码归一化。
/// 使用 dart:io HttpClient（桌面端不引入代理；TS 侧 fetchWithProxy 的代理
/// 能力后续如需再接入）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'config.dart';
import 'cookie.dart';
import 'crypto.dart' as nm;
import 'device.dart';
import 'xeapi.dart' as xeapi;

/// 调用方传入的可选参数
class NeteaseRequestOptions {
  NeteaseRequestOptions({
    this.crypto = '',
    this.cookie,
    this.ua = '',
    this.realIP,
    this.ip,
    this.eR,
    this.domain = '',
    this.checkToken = false,
  });

  /// 加密方式；省略时默认 eapi
  String crypto;
  /// 预注入 cookie，可为字符串或对象
  Object? cookie;
  /// 自定义 User-Agent
  String ua;
  /// 真实 IP（X-Real-IP / X-Forwarded-For）
  String? realIP;
  String? ip;
  /// 是否让服务端加密响应体（仅 weapi/eapi 有效）
  bool? eR;
  /// 自定义 Referer/域名覆盖
  String domain;
  /// 强制附加 anti-cheat token（暂未启用）
  bool checkToken;
}

/// 响应统一结构（status/body/cookie 在请求流程中会被逐步填充，故非 final）
class NeteaseResponse {
  NeteaseResponse({required this.status, required this.body, required this.cookie});

  int status;
  Map<String, dynamic> body;
  List<String> cookie;
}

/// 非 200 响应抛出的错误
class NeteaseRequestError implements Exception {
  NeteaseRequestError(this.response);

  final NeteaseResponse response;

  @override
  String toString() {
    final body = response.body;
    final code = body['code'] ?? response.status;
    final msg = body['msg'] ?? body['message'] ?? '';
    return 'netease $code${msg.isEmpty ? '' : ': $msg'}';
  }
}

/// macOS 客户端日志接口需要桌面浏览器 UA
const _osxUserAgent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// 生成 WNMCID（进程级常量）：6 位小写字母.时间戳.01.0
final String _wnmcid = _genWnmcid();

String _genWnmcid() {
  final chars = 'abcdefghijklmnopqrstuvwxyz';
  final rng = Random.secure();
  final s = List.generate(6, (_) => chars[rng.nextInt(26)]).join();
  return '$s.${DateTime.now().millisecondsSinceEpoch}.01.0';
}

/// 每次请求生成：timestamp_XXXX 的递增式 id
String _generateRequestId() {
  final rand = Random.secure().nextInt(1000).toString().padLeft(4, '0');
  return '${DateTime.now().millisecondsSinceEpoch}_$rand';
}

/// 补齐 cookie：注入 _ntes_nuid/_ntes_nnid/WNMCID/deviceId/appver 等客户端必备字段
Map<String, String> _processCookieObject(
  Map<String, String> cookie,
  String uri,
) {
  final rng = Random.secure();
  String hexBytes(int n) => List.generate(n, (_) => rng.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  final ntesNuid = cookie['_ntes_nuid'] ?? hexBytes(16);
  final os = nmOsMap[cookie['os'] ?? 'pc'] ?? nmOsMap['pc']!;
  final now = DateTime.now().millisecondsSinceEpoch;

  final processed = <String, String>{
    ...cookie,
    '__remember_me': 'true',
    'ntes_kaola_ad': '1',
    '_ntes_nuid': cookie['_ntes_nuid'] ?? ntesNuid,
    '_ntes_nnid': cookie['_ntes_nnid'] ?? '$ntesNuid,$now',
    'WNMCID': cookie['WNMCID'] ?? _wnmcid,
    'WEVNSM': cookie['WEVNSM'] ?? '1.0.0',
    'osver': cookie['osver'] ?? os['osver']!,
    'deviceId': cookie['deviceId'] ?? nmGetDeviceId(),
    'os': cookie['os'] ?? os['os']!,
    'channel': cookie['channel'] ?? os['channel']!,
    'appver': cookie['appver'] ?? os['appver']!,
  };

  // 登录类接口不带 NMTID（服务端要求）
  if (!uri.contains('login')) {
    processed['NMTID'] = hexBytes(8);
  }

  if (processed['MUSIC_U'] == null) {
    final anon = nmGetAnonymousToken();
    if (anon.isNotEmpty) processed['MUSIC_A'] = anon;
  }

  return processed;
}

/// 根据加密方式 + 设备类型选择 User-Agent
String _chooseUserAgent(String crypto, String uaType) {
  final map = nmUaMap[crypto];
  return map?[uaType] ?? '';
}

/// 宽松的 boolean 解析
bool _toBoolean(Object? val) {
  if (val is bool) return val;
  if (val == '') return false;
  return val == 'true' || val == '1' || val == 1;
}

final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 12);

/// 关闭底层连接池
void nmCloseHttpClient() => _client.close(force: true);

/// 构造并发送请求
///
/// [uri] 形如 `/api/w/login`；weapi 会自动替换前缀为 `/weapi/`。
Future<NeteaseResponse> createRequest(
  String uri,
  Map<String, dynamic> data,
  NeteaseRequestOptions options,
) async {
  final headers = <String, String>{};
  final ip = options.realIP ?? options.ip ?? '';
  if (ip.isNotEmpty) {
    headers['X-Real-IP'] = ip;
    headers['X-Forwarded-For'] = ip;
  }

  // 归一化 cookie 到对象并做一次补全
  final cookieObj = options.cookie is String
      ? nmCookieToJson(options.cookie as String)
      : (options.cookie is Map
          ? Map<String, String>.from(options.cookie as Map)
          : <String, String>{});
  final cookie = _processCookieObject(cookieObj, uri);
  headers['Cookie'] = nmCookieObjToString(cookie);

  final cryptoMode = options.crypto.isEmpty ? 'eapi' : options.crypto;
  final csrfToken = cookie['__csrf'] ?? '';
  final useER = _toBoolean(
      options.eR ?? data['e_r'] ?? nmEncryptResponse);
  data['e_r'] = useER;

  String url;
  Map<String, dynamic> encryptData;
  var isXeapi = false;
  var needDecrypt = false;

  switch (cryptoMode) {
    case 'weapi':
      headers['Referer'] = options.domain.isEmpty ? nmDomain : options.domain;
      headers['User-Agent'] = options.ua.isEmpty ? _chooseUserAgent('weapi', 'pc') : options.ua;
      data['csrf_token'] = csrfToken;
      final enc = nm.nmWeapi(data);
      encryptData = {'params': enc.params, 'encSecKey': enc.encSecKey};
      url = '${options.domain.isEmpty ? nmDomain : options.domain}/weapi/${uri.substring(5)}';
      break;
    case 'linuxapi':
      headers['User-Agent'] = options.ua.isEmpty ? _chooseUserAgent('linuxapi', 'linux') : options.ua;
      final domain = options.domain.isEmpty ? nmDomain : options.domain;
      encryptData = {
        'eparams': nm.nmLinuxapi({
          'method': 'POST',
          'url': '$domain$uri',
          'params': data,
        }),
      };
      url = '$domain/api/linux/forward';
      break;
    case 'xeapi':
      isXeapi = true;
      needDecrypt = true;
      final publicKeyState = await xeapi.nmEnsureXeapiKey(cookie['deviceId'] ?? '');
      final xeapiOs = cookie['os'] == 'android' ? cookie['os']! : 'android';
      final xeapiAppver =
          cookie['os'] == 'android' && cookie['appver'] != null ? cookie['appver']! : '9.1.65';
      final xeapiOsver =
          cookie['os'] == 'android' && cookie['osver'] != null ? cookie['osver']! : '16';
      final xeapiBuildver =
          cookie['buildver'] ?? '${DateTime.now().millisecondsSinceEpoch}'.substring(0, 10);
      headers['User-Agent'] = options.ua.isEmpty ? _chooseUserAgent('api', 'android') : options.ua;
      headers['X-Client-Enc-State'] = 'ENCRYPTED';
      headers['x-aeapi'] = 'true';
      headers['x-deviceid'] = cookie['deviceId'] ?? '';
      headers['x-os'] = xeapiOs;
      headers['x-osver'] = xeapiOsver;
      headers['x-appver'] = xeapiAppver;
      headers['x-sdeviceid'] = cookie['sDeviceId'] ?? cookie['deviceId'] ?? '';
      headers['x-buildver'] = xeapiBuildver;
      if (cookie['MUSIC_U'] != null) headers['x-music-u'] = cookie['MUSIC_U']!;
      headers['Cookie'] = nmCookieObjToString({
        ...cookie,
        'os': xeapiOs,
        'osver': xeapiOsver,
        'appver': xeapiAppver,
        'buildver': xeapiBuildver,
        'sDeviceId': cookie['sDeviceId'] ?? cookie['deviceId'] ?? '',
      });
      final session = xeapi.nmGetXeapiSession();
      final domain = options.domain.isEmpty ? nmXeapiDomain : options.domain;
      url = '$domain/xeapi/${uri.substring(5)}';
      final enc = nm.nmXeapi(uri, data, nm.NmXeapiOptions(
        publicKeyState: publicKeyState,
        sessionId: session.sessionId,
        sessionKey: session.sessionKey,
        os: xeapiOs,
      ));
      encryptData = {'B': enc.B, 'S': enc.S, 'R': enc.R};
      break;
    case 'eapi':
    case 'api':
      final header = <String, dynamic>{
        'osver': cookie['osver'],
        'deviceId': cookie['deviceId'],
        'os': cookie['os'],
        'appver': cookie['appver'],
        'versioncode': cookie['versioncode'] ?? '140',
        'mobilename': cookie['mobilename'] ?? '',
        'buildver': cookie['buildver'] ?? '${DateTime.now().millisecondsSinceEpoch}'.substring(0, 10),
        'resolution': cookie['resolution'] ?? '1920x1080',
        '__csrf': csrfToken,
        'channel': cookie['channel'],
        'requestId': _generateRequestId(),
      };
      if (cookie['MUSIC_U'] != null) header['MUSIC_U'] = cookie['MUSIC_U'];
      if (cookie['MUSIC_A'] != null) header['MUSIC_A'] = cookie['MUSIC_A'];
      headers['Cookie'] = nmCookieObjToString(header);
      headers['User-Agent'] = options.ua.isNotEmpty
          ? options.ua
          : (cookie['os'] == 'osx' ? _osxUserAgent : _chooseUserAgent('api', 'iphone'));
      final domain = options.domain.isEmpty ? nmApiDomain : options.domain;
      if (cryptoMode == 'eapi') {
        data['header'] = header;
        encryptData = {'params': nm.nmEapi(uri, data)};
        url = '$domain/eapi/${uri.substring(5)}';
      } else {
        url = '$domain$uri';
        encryptData = data;
      }
      break;
    default:
      throw StateError('Unknown crypto: $cryptoMode');
  }

  final body = Uri(queryParameters: encryptData.map((k, v) => MapEntry(k, '$v'))).query;
  headers['Content-Type'] = 'application/x-www-form-urlencoded';

  // 响应预处理
  final answer = NeteaseResponse(status: 500, body: {}, cookie: []);

  HttpClientRequest httpRequest;
  try {
    httpRequest = await _client.postUrl(Uri.parse(url)).timeout(const Duration(seconds: 12));
    headers.forEach(httpRequest.headers.set);
    httpRequest.write(body);
  } catch (err) {
    answer.status = 502;
    answer.body = {'code': 502, 'msg': '$err'};
    throw NeteaseRequestError(answer);
  }

  HttpClientResponse res;
  try {
    res = await httpRequest.close().timeout(const Duration(seconds: 12));
  } catch (err) {
    answer.status = 502;
    answer.body = {'code': 502, 'msg': '$err'};
    throw NeteaseRequestError(answer);
  }

  // 收集 set-cookie（多值头），去除 Domain 属性
  final setCookieRaw = res.headers[HttpHeaders.setCookieHeader];
  answer.cookie = (setCookieRaw ?? [])
      .map((x) => x.replaceAll(RegExp(r'\s*Domain=[^(;|$)]+;*'), ''))
      .toList();

  // xeapi 会话密钥由响应头下发，缓存供后续请求复用
  if (isXeapi) {
    final ssid = res.headers.value('x-encr-ssid');
    final sskey = res.headers.value('x-encr-sskey');
    if (ssid != null && sskey != null) xeapi.nmUpdateXeapiSession(ssid, sskey);
  }

  Map<String, dynamic> parsed;
  try {
    if (needDecrypt) {
      final raw = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      final bytes = Uint8List.fromList(raw);
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
      final decrypted = isXeapi
          ? nm.nmXeapiResDecrypt(bytes)
          : nm.nmEapiResDecrypt(hex, aeapi: headers['x-aeapi'] == 'true');
      parsed = (decrypted is Map<String, dynamic>) ? decrypted : {'code': res.statusCode};
    } else {
      final text = await res.transform(utf8.decoder).join();
      try {
        parsed = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {
        parsed = {'code': res.statusCode, 'raw': text};
      }
    }
  } catch (_) {
    parsed = {'code': res.statusCode, 'msg': 'parse failed'};
  }

  if (parsed['code'] != null) parsed['code'] = (parsed['code'] as num).toInt();
  var status = (parsed['code'] as int?) ?? res.statusCode;
  if (nmSpecialStatusCodes.contains(status)) status = 200;

  status = (status > 100 && status < 600) ? status : 400;
  answer.status = status;
  answer.body = parsed;

  if (status == 200) return answer;
  throw NeteaseRequestError(answer);
}
