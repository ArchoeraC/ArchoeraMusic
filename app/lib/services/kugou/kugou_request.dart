/// 酷狗请求层（Dart 移植）
///
/// 对齐 apis/kugou/core/request.ts + KuGouMusicApi util/request.js：
/// - 搜索/歌词接口无鉴权（mobilecdn 需 http，证书是共享 CDN 的）
/// - 取 URL 需先 /register/dev 拿真实 dfid，再带 android 签名访问
///   gateway.kugou.com/v5/url
///
/// 成功码约定不统一：songsearch/mobilecdn 用 error_code=0，lyrics 用
/// error_code=200；v5/url 用 status=1。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'kugou_crypto.dart';

/// 主搜索（带封面）：mobilecdn 的 /api/v3/search/song，公网无鉴权
const kgMobilecdnUrl = 'http://mobilecdn.kugou.com/api/v3/search/song';

/// 热搜：mobilecdn 的 /api/v3/search/hot，公网无鉴权
const kgSearchHotUrl = 'http://mobilecdn.kugou.com/api/v3/search/hot';

/// 兜底搜索：songsearch.kugou.com（无封面）
const kgSearchUrl = 'https://songsearch.kugou.com/song_search_v2';

/// 设备注册：拿真实 dfid（v5/url 前置条件）
const kgRegisterUrl = 'https://userservice.kugou.com/risk/v2/r_register_dev';

/// 取歌曲 URL（签名 + key）
const kgSongUrl = 'https://gateway.kugou.com/v5/url';

/// 扫码登录：二维码 key 生成（web 签名）
const kgQrKeyUrl = 'https://login-user.kugou.com/v2/qrcode';

/// 扫码登录：轮询扫码状态（web 签名；status=4 时返回 token/userid）
const kgQrCheckUrl = 'https://login-user.kugou.com/v2/get_userinfo_qrcode';

/// 扫码登录页（拼上 qrcode=key 后用 qr 库生成二维码图）
const kgQrLoginPage = 'https://h5.kugou.com/apps/loginQRCode/html/index.html';

/// 歌词搜索/下载接口
const kgLyricSearchUrl = 'http://lyrics.kugou.com/search';
const kgLyricDownloadUrl = 'http://lyrics.kugou.com/download';

/// 歌词接口需要的伪装 headers（来自 KuGou2012 PC 客户端）
const kgLyricHeaders = <String, String>{
  'KG-RC': '1',
  'KG-THash': 'expand_search_manager.cpp:852736169:451',
  'User-Agent': 'KuGou2012-9020-ExpandSearchManager',
};

/// android 客户端 UA（对齐 KuGouMusicApi request.js）
const kgAndroidUa = 'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi';

/// v5/url 基础请求参数（对齐 KuGouMusicApi module/song_url.js，
/// 概念版 lite：MoeKoeMusic 后端 --platform=lite，appid 3116/clientver 11440）
const kgSongUrlBase = <String, dynamic>{
  'album_id': 0,
  'area_code': 1,
  'ssa_flag': 'is_fromtrack',
  'version': 11430,
  'page_id': 967177915,
  'album_audio_id': 0,
  'behavior': 'play',
  'pid': 411,
  'cmd': 26,
  'pidversion': 3001,
  'IsFreePart': 0,
  'ppage_id': '356753938,823673182,967485191',
  'cdnBackup': 1,
  'module': '',
  'clientver': 11440,
};

/// register_dev 的设备信息（对齐 module/register_dev.js 默认值）
const _kgDevice = <String, dynamic>{
  'availableRamSize': 4983533568,
  'availableRomSize': 48114719,
  'availableSDSize': 48114717,
  'basebandVer': '',
  'batteryLevel': 100,
  'batteryStatus': 3,
  'brand': 'Redmi',
  'buildSerial': 'unknown',
  'device': 'marble',
  'imei': 'unknown',
  'imsi': '',
  'manufacturer': 'Xiaomi',
  'uuid': 'unknown',
  'accelerometer': false,
  'accelerometerValue': '',
  'gravity': false,
  'gravityValue': '',
  'gyroscope': false,
  'gyroscopeValue': '',
  'light': false,
  'lightValue': '',
  'magnetic': false,
  'magneticValue': '',
  'orientation': false,
  'orientationValue': '',
  'pressure': false,
  'pressureValue': '',
  'step_counter': false,
  'step_counterValue': '',
  'temperature': false,
  'temperatureValue': '',
};

/// 一次 KG GET 请求 → 解析 JSON body；失败抛 [KgApiException] 由上层兜底
Future<dynamic> kgGet(
  Uri uri, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(uri).timeout(timeout);
    headers?.forEach(req.headers.set);
    final res = await req.close().timeout(timeout);
    if (res.statusCode != 200) {
      throw KgApiException('KG HTTP ${res.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes, allowMalformed: true));
  } finally {
    client.close(force: true);
  }
}

/// 一次 KG POST 请求（register_dev 用），返回原始字节
Future<Uint8List> kgPost(
  Uri uri, {
  required String body,
  required Map<String, String> headers,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(uri).timeout(timeout);
    headers.forEach(req.headers.set);
    req.write(body);
    final res = await req.close().timeout(timeout);
    if (res.statusCode != 200) {
      throw KgApiException('KG POST HTTP ${res.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
    }
    return Uint8List.fromList(bytes);
  } finally {
    client.close(force: true);
  }
}

/// KG 业务异常
class KgApiException implements Exception {
  KgApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 按「签名原文」拼接 query：`key=value`（空值保留 `=`，逗号等不做
/// URL 编码）。服务器按收到的参数原文校验 signature，Uri 的
/// queryParameters 会把空值变成裸键（丢 `=`）、编码逗号，导致验签失败。
String kgQueryString(Map<String, dynamic> params) =>
    params.entries.map((e) => '${e.key}=${e.value}').join('&');

/// 值做标准 URL 编码的 query（扫码登录用：qrcode_txt 含 `://?&` 等，
/// 必须编码，否则会被当作参数分隔符截断；服务器解码后按原文验签）。
String kgQueryStringEncoded(Map<String, dynamic> params) => params.entries
    .map((e) => '${e.key}=${Uri.encodeQueryComponent('${e.value}')}')
    .join('&');

/// 生成扫码登录二维码 key。
/// 对齐 KuGouMusicApi module/login_qr_key.js：GET login-user.kugou.com
/// /v2/qrcode，`appid=1001`（web 登录专用，覆盖平台 appid）+ srcappid，
/// web 签名。返回 key，二维码内容 = `$kgQrLoginPage?qrcode=$key`。
Future<String> kgQrKey({String? mid}) async {
  mid ??= kgCalcMid(kgRandomString(16));
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final params = <String, dynamic>{
    'appid': 1001,
    'type': 1,
    'plat': 4,
    'qrcode_txt': '$kgQrLoginPage?appid=$kgSrcAppid&',
    'srcappid': kgSrcAppid,
    'dfid': '-',
    'mid': mid,
    'uuid': '-',
    'clientver': kgLiteClientver,
    'clienttime': ts,
  };
  params['signature'] = kgSignatureWeb(params);
  final uri = Uri.parse('$kgQrKeyUrl?${kgQueryStringEncoded(params)}');
  final body = await kgGet(uri, headers: _kgBaseHeaders(mid, ts));
  final data = body is Map ? body['data'] : null;
  final key = data is Map ? data['qrcode']?.toString() : null;
  if (key == null || key.isEmpty) {
    throw KgApiException('login_qr_key 未返回 key: $body');
  }
  return key;
}

/// 轮询扫码状态。
/// 对齐 KuGouMusicApi module/login_qr_check.js：GET /v2/get_userinfo_qrcode，
/// web 签名。返回 {status, token, userid, nickname}：
/// status 0=已过期 / 1=等待扫码 / 2=已扫待确认 / 4=登录成功（带 token）。
Future<Map<String, dynamic>> kgQrCheck(String key, {String? mid}) async {
  mid ??= kgCalcMid(kgRandomString(16));
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final params = <String, dynamic>{
    'plat': 4,
    'appid': kgLiteAppid,
    'srcappid': kgSrcAppid,
    'qrcode': key,
    'dfid': '-',
    'mid': mid,
    'uuid': '-',
    'clientver': kgLiteClientver,
    'clienttime': ts,
  };
  params['signature'] = kgSignatureWeb(params);
  final uri = Uri.parse('$kgQrCheckUrl?${kgQueryStringEncoded(params)}');
  final body = await kgGet(uri, headers: _kgBaseHeaders(mid, ts));
  final data = body is Map && body['data'] is Map
      ? (body['data'] as Map).cast<String, dynamic>()
      : const <String, dynamic>{};
  return {
    'status': data['status'],
    'token': data['token']?.toString(),
    'userid': data['userid']?.toString(),
    'nickname': data['nickname']?.toString(),
  };
}

/// 登录用户详情（user_detail.js：POST usercenter.kugou.com/v3/get_my_info）。
///
/// body：`{visit_time, usertype, p, userid}`，其中 p = raw RSA 加密
/// `{token, clienttime}`（cryptoRSAEncrypt，零填充模幂）大写 hex；
/// android 签名 + `x-router: usercenter.kugou.com` 头。
/// 返回 data：`{nickname, pic(头像), gender, vip_type, ...}`。
Future<Map<String, dynamic>> kgGetMyInfo({
  required String token,
  required String userid,
  String dfid = '-',
  String? mid,
}) async {
  mid ??= kgCalcMid(kgRandomString(16));
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final p = kgRsaRawEncryptHex(jsonEncode({'token': token, 'clienttime': ts}));
  final body = await kgGateway(
    '/v3/get_my_info',
    method: 'POST',
    query: {'plat': 1},
    body: {
      'visit_time': ts,
      'usertype': 1,
      'p': p,
      'userid': int.tryParse(userid) ?? 0,
    },
    headers: {'x-router': 'usercenter.kugou.com'},
    baseUrl: 'https://usercenter.kugou.com',
    dfid: dfid,
    mid: mid,
    token: token,
    userid: userid,
  );
  final data = body is Map && body['data'] is Map
      ? (body['data'] as Map).cast<String, dynamic>()
      : const <String, dynamic>{};
  return data;
}

/// 通用 kg-* 请求头（对齐 KuGouMusicApi request.js，无 x-router）
Map<String, String> _kgBaseHeaders(String mid, int ts) => {
  'User-Agent': kgAndroidUa,
  'dfid': '-',
  'clienttime': '$ts',
  'mid': mid,
  'kg-rc': '1',
  'kg-thash': '5d816a0',
  'kg-rec': '1',
  'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
};

/// 注册设备 → 返回 (dfid)。dfid 用于后续 /v5/url 请求。
///
/// 对齐 KuGouMusicApi：POST userservice.kugou.com/risk/v2/r_register_dev，
/// AES-CBC 加密设备信息 + RSA-PKCS1 加密 {aes, uid, token}，android 签名。
/// 采用概念版 lite 平台（appid 3116/clientver 11440/lite 盐/lite 公钥，
/// 对齐 MoeKoeMusic 后端 --platform=lite；标准版参数已被官方风控）。
/// [mid] 可传入外部生成（保持与 /v5/url 同一设备身份），缺省内部随机。
Future<String> kgRegisterDevice({String? mid}) async {
  mid ??= kgCalcMid(kgRandomString(16));
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  // imei/uuid 用 32 位 hex 设备标识（对齐 KUGOU_API_GUID = md5(getGuid())）
  final guid = kgMd5(kgRandomString(24));
  final device = <String, dynamic>{..._kgDevice, 'imei': guid, 'uuid': guid};

  // AES 加密设备信息（密钥随请求回传，用于解密响应）
  final secretKey = kgRandomString(6).toLowerCase();
  final cipher = kgAesEncryptBase64(jsonEncode(device), secretKey);

  // RSA 加密 {aes, uid, token}（概念版 lite 公钥）
  final p = kgRsaPkcs1EncryptHex(
    jsonEncode({'aes': secretKey, 'uid': 0, 'token': ''}),
    pem: kgLitePublicKeyPem,
  );

  final params = <String, dynamic>{
    'part': 1,
    'platid': 1,
    'p': p,
    'dfid': '-',
    'mid': mid,
    'uuid': '-',
    'appid': kgLiteAppid,
    'clientver': kgLiteClientver,
    'clienttime': ts,
  };
  params['signature'] = kgSignature(params, data: cipher, salt: kgLiteSignSalt);

  final uri = Uri.parse('$kgRegisterUrl?${kgQueryString(params)}');
  final bytes = await kgPost(
    uri,
    body: cipher,
    headers: {
      'User-Agent': kgAndroidUa,
      'dfid': '-',
      'clienttime': '$ts',
      'mid': mid,
      'kg-rc': '1',
      'kg-thash': '5d816a0',
      'kg-rec': '1',
      'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
      'Content-Type': 'text/plain;charset=utf-8',
    },
  );

  final text = kgAesDecryptString(base64.encode(bytes), secretKey);
  final body = jsonDecode(text);
  if (body is! Map<String, dynamic>) throw KgApiException('register_dev 响应异常');
  final dfid = body['data'] is Map ? body['data']['dfid']?.toString() : null;
  if (dfid == null || dfid.isEmpty) {
    throw KgApiException('register_dev 未返回 dfid: $text');
  }
  return dfid;
}

/// 校验网关响应：`status:0` / `error_code != 0` 视为业务失败（抛异常）。
void _checkKgStatus(dynamic body) {
  if (body is! Map) return;
  final status = body['status'];
  if (status is num && status == 0) {
    throw KgApiException(
      'KG status=0: ${body['error_msg'] ?? body['msg'] ?? body}',
    );
  }
  final ec = body['error_code'];
  if (ec is num && ec != 0) {
    throw KgApiException('KG error_code=$ec: ${body['error_msg'] ?? body}');
  }
}

/// 统一网关请求（对齐 KuGouMusicApi util/request.js createRequest）。
///
/// 流程（与 request.js 完全一致）：
/// 1. 注入默认参数 `{dfid, mid, uuid:'-', appid, clientver, clienttime}`
///    及登录态 `token` / `userid`（非空才注入）；
/// 2. [encryptKey] 时追加 `key = signKey(hash, mid, userid, appid)`；
/// 3. 序列化 [body]（POST JSON 原文参与签名）；
/// 4. android 签名（lite 盐）生成 `signature` 追加到 query；
/// 5. 组装 kg-* 头 + [headers]（x-router / kg-tid）后发送。
///
/// 响应非 2xx / status=0 / error_code!=0 抛 [KgApiException]；成功返回解析后的
/// JSON body（Map / List / 原始值）。
Future<dynamic> kgGateway(
  String path, {
  required String method,
  Map<String, dynamic>? query,
  Map<String, dynamic>? body,
  Map<String, String>? headers,
  String baseUrl = 'https://gateway.kugou.com',
  bool encryptKey = false,
  String dfid = '-',
  String? mid,
  String? token,
  String? userid,
  Duration timeout = const Duration(seconds: 10),
}) async {
  mid ??= kgCalcMid(kgRandomString(16));
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  // 默认参数注入（对齐 request.js defaultParams）
  final params = <String, dynamic>{
    'dfid': dfid,
    'mid': mid,
    'uuid': '-',
    'appid': kgLiteAppid,
    'clientver': kgLiteClientver,
    'clienttime': ts,
    ...?query,
  };
  if (token != null && token.isNotEmpty) params['token'] = token;
  if (userid != null && userid.isNotEmpty && userid != '0') {
    params['userid'] = userid;
  }

  // encryptKey：key = signKey(hash, mid, userid, appid)
  if (encryptKey) {
    final hash = (params['hash'] ?? '').toString().toLowerCase();
    params['key'] = kgSignKey(
      hash,
      mid,
      int.tryParse(userid ?? '') ?? 0,
      kgLiteAppid,
      salt: kgLiteKeySalt,
    );
  }

  // POST body 序列化（空 body → ''，与 request.js `data = ''` 一致）
  final data = body == null ? '' : jsonEncode(body);

  // android 签名（lite 盐）
  params['signature'] = kgSignature(params, data: data, salt: kgLiteSignSalt);

  final uri = Uri.parse('$baseUrl$path?${kgQueryString(params)}');
  final reqHeaders = <String, String>{
    'User-Agent': kgAndroidUa,
    'dfid': dfid,
    'clienttime': '$ts',
    'mid': mid,
    'kg-rc': '1',
    'kg-thash': '5d816a0',
    'kg-rec': '1',
    'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
    ...?headers,
  };

  final dynamic resp;
  if (method == 'GET') {
    resp = await kgGet(uri, headers: reqHeaders, timeout: timeout);
  } else {
    final bytes = await kgPost(
      uri,
      body: data,
      headers: {
        ...reqHeaders,
        'Content-Type': 'application/json;charset=UTF-8',
      },
      timeout: timeout,
    );
    resp = jsonDecode(utf8.decode(bytes, allowMalformed: true));
  }
  _checkKgStatus(resp);
  return resp;
}

/// ── 歌曲评论（commentsv2/getCommentWithLike，无需登录/签名） ────────

/// 评论网关
const kgCommentUrl = 'https://mcomment.kugou.com/index.php';

/// 歌曲评论固定 code（对齐安卓逆向：code=fc4be23b4e972707f36b8a828a93ba8a）
const kgCommentCode = 'fc4be23b4e972707f36b8a828a93ba8a';

/// 评论接口伪装 UA（Android COMMENT 通道）
const kgCommentUa = 'Android810-AndroidPhone-10659-14-0-COMMENT-wifi';

/// 获取歌曲评论（POST mcomment.kugou.com/index.php）。
///
/// 参数：`r=commentsv2/getCommentWithLike&code=<歌曲code>&p=<页>&pagesize=<每页>`，
/// body 为 `extdata=<歌曲hash>`。返回原始响应（list/count/current_page 等）。
Future<Map<String, dynamic>> kgComments(
  String hash, {
  int page = 1,
  int pagesize = 20,
}) async {
  final client = HttpClient();
  try {
    final query =
        'r=commentsv2/getCommentWithLike'
        '&code=$kgCommentCode'
        '&p=$page'
        '&pagesize=$pagesize'
        '&platform=android';
    final req = await client
        .postUrl(Uri.parse('$kgCommentUrl?$query'))
        .timeout(const Duration(seconds: 10));
    req.headers.set(HttpHeaders.userAgentHeader, kgCommentUa);
    req.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/x-www-form-urlencoded',
    );
    req.write('extdata=$hash');
    final res = await req.close().timeout(const Duration(seconds: 10));
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    if (res.statusCode != 200) {
      throw KgApiException('KG comment HTTP ${res.statusCode}');
    }
    final body = jsonDecode(utf8.decode(bytes));
    if (body is! Map<String, dynamic>) {
      throw KgApiException('KG comment 响应异常: $body');
    }
    return body;
  } finally {
    client.close(force: true);
  }
}
