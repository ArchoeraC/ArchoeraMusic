// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoAuth 账号密码登录（纯 HTTP，不打开浏览器、不注册深链）。
///
/// 复刻官方 PC 客户端的 SSO 链路，只把其中的「系统浏览器」换成内置 HTTP
/// 客户端。全部请求都不需要我方 OAuth 客户端身份，也不持有任何客户端密钥：
///
/// 1. `POST {music}/api/user/sso/start`
///    NekoMusic 后端用它自己的机密客户端生成 `state` / `nonce` / PKCE，
///    并把授权地址返回给我们；顺带从该地址的 origin 得到 NekoAuth 地址
///    （因此不硬编码 `auth.nekocore.cn`，换部署也能用）。
/// 2. `POST {auth}/api/auth/login`
///    账号密码换 Auth access token；`Set-Cookie` 里的 `refresh_token` 是
///    整条授权链的根（14 天滚动），必须随会话一起加密保存。
/// 3. `GET {auth}/api/oauth/authorize?<start 给的 query 原样>`
///    NekoMusic 的 `redirect_uri` 是第一方 https，NekoAuth 会直接自动同意并
///    在 `redirectUrl` 里给出授权码；若部署未配置第一方父域（会返回 null），
///    退回 `POST /api/oauth/authorize/decision` 显式同意。
/// 4. `GET redirectUrl`（**不跟随重定向**）
///    授权码由 NekoMusic 后端用它自己的密钥交换；我们只从 `Location` 里取
///    一次性 `handoff`（120 秒有效）。
/// 5. `POST {music}/api/user/sso/claim`
///    换回 NekoAuth access token（本客户端有效期约一年）。
///
/// 该 token 绑定创建它的 Auth 会话族：会话族过期 / 被撤销（改密、账号中心
/// 撤销设备）后立即失效，需用保存的 `refresh_token` 静默续期，失败才重新
/// 输入账号密码。
///
/// **边界**：不保存密码；不接入注册 / 邮箱验证码 / 滑块验证；不伪装浏览器
/// 或 Android（`device` 如实上报桌面平台），也不伪造 `Origin` 等来源头。
/// 若服务端将来收紧第一方校验导致该链路失效，宁可降级为扫码登录，也不在
/// 客户端伪造来源。协议依据见 `docs/neko-source-identity.md`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../services/neko/neko_identity.dart';
import '../../services/neko/neko_types.dart';
import 'neko_client.dart'
    show NekoApiException, NekoErrorKind, kDefaultNekoBaseUrl;

/// SSO 客户端类型：官方 PC 端。
///
/// 用 `pc` 时回调落在 `/sso/native-complete?client=pc&handoff=…`（纯相对跳转），
/// 我们只读 `Location`，不涉及任何深链协议。
const String kNekoAuthSsoClient = 'pc';

/// Auth 会话刷新令牌的 Cookie 名（NekoAuth `auth.cookie.name` 默认值）。
const String kNekoAuthRefreshCookie = 'refresh_token';

/// 一次登录成功后的会话材料。
class NekoAuthSession {
  const NekoAuthSession({
    required this.token,
    required this.authRefreshToken,
    required this.user,
    this.expiresAt,
    this.authBaseUrl,
  });

  /// NekoMusic API 使用的 NekoAuth access token。
  final String token;

  /// Auth 会话刷新令牌（Cookie 值）。空串表示本次登录没拿到
  /// （登录响应未下发 `refresh_token` 时），不能用于静默续期。
  final String authRefreshToken;

  /// 服务端给出的用户资料；缺失时为 null。
  final NekoUser? user;

  /// access token 过期时间（本地解析 JWT `exp`；解析失败为 null）。
  final DateTime? expiresAt;

  /// 本次登录使用的 NekoAuth 根地址（注销会话时需要；未知为 null）。
  final String? authBaseUrl;
}

/// 账号密码登录能力（`NekoApi` 侧只依赖该接口，便于单测替换）。
abstract class NekoAuthService {
  /// 用账号密码换取 NekoMusic 可用的 access token。
  Future<NekoAuthSession> signIn({
    required String identifier,
    required String password,
  });

  /// 用保存的 Auth 刷新令牌静默续期（不弹任何界面）。
  ///
  /// 会话已失效时抛 [NekoErrorKind.auth] 的 [NekoApiException]；网络 / 服务端
  /// 暂时不可用时抛其它类别，调用方据此决定「保留登录态稍后重试」还是
  /// 「清会话要求重新登录」。
  Future<NekoAuthSession> refresh(String authRefreshToken);

  /// 注销账号密码登录建立的 Auth 会话族（退出登录时调用）。
  ///
  /// 该会话族是所有 NekoAuth 令牌（含 OAuth 授权链）的根：服务端撤销后，
  /// 本机拿到的 access token / 刷新令牌立即失效，也不会留下 14 天的可用会话。
  /// 只影响本次登录的这一族，不影响用户其它设备与网页登录。
  Future<void> revokeSession(
    String authRefreshToken, {
    String? authBaseUrl,
  });
}

/// NekoAuth / NekoMusic SSO 的 HTTP 实现。
class NekoAuthClient implements NekoAuthService {
  NekoAuthClient({
    String? musicBaseUrl,
    String? authBaseUrl,
    this.timeout = const Duration(seconds: 15),
  }) : _musicBaseUrl = _normalizeBase(musicBaseUrl ?? kDefaultNekoBaseUrl),
       _authBaseUrl = authBaseUrl == null ? null : _normalizeBase(authBaseUrl);

  final String _musicBaseUrl;

  /// 单次请求超时。
  final Duration timeout;

  /// NekoAuth 根地址：首次 [signIn] / [refresh] 时从 start 返回的授权地址推断。
  String? _authBaseUrl;

  /// 当前已知的 NekoAuth 根地址（未发起过登录时为 null）。
  String? get authBaseUrl => _authBaseUrl;

  @override
  Future<NekoAuthSession> signIn({
    required String identifier,
    required String password,
  }) async {
    final sso = await _startSso(silent: false);
    final login = await _postJson(
      _authUri('/api/auth/login'),
      body: {
        'identifier': identifier,
        'password': password,
        'device': _deviceProfile(),
      },
    );
    _ensureOk(login, fallback: '登录失败');
    final accessToken = _stringOf(login.json?['accessToken']);
    if (accessToken.isEmpty) {
      throw NekoApiException('NekoAuth 未返回访问令牌');
    }
    return _authorizeAndClaim(
      sso,
      accessToken,
      _cookieValue(login.cookies, kNekoAuthRefreshCookie),
    );
  }

  @override
  Future<NekoAuthSession> refresh(String authRefreshToken) async {
    if (authRefreshToken.isEmpty) {
      throw NekoApiException(
        '登录态已失效，请重新登录',
        kind: NekoErrorKind.auth,
      );
    }
    final sso = await _startSso(silent: true);
    final res = await _postJson(
      _authUri('/api/auth/refresh'),
      cookies: {kNekoAuthRefreshCookie: authRefreshToken},
    );
    if (res.status == 401) {
      throw NekoApiException(
        _messageOf(res.json) ?? '登录态已失效，请重新登录',
        statusCode: 401,
        kind: NekoErrorKind.auth,
      );
    }
    _ensureOk(res, fallback: '登录态续期失败');
    final accessToken = _stringOf(res.json?['accessToken']);
    if (accessToken.isEmpty) {
      throw NekoApiException('NekoAuth 未返回访问令牌');
    }
    final rotated = _cookieValue(res.cookies, kNekoAuthRefreshCookie);
    try {
      return await _authorizeAndClaim(
        sso,
        accessToken,
        rotated.isEmpty ? authRefreshToken : rotated,
      );
    } on NekoApiException catch (e) {
      // 授权接口 401 说明 Auth 会话族已经没了（登录态彻底失效），
      // 归类为 auth，让调用方清会话而不是无限重试。
      if (e.statusCode == 401) {
        throw NekoApiException(
          e.message,
          statusCode: 401,
          kind: NekoErrorKind.auth,
        );
      }
      rethrow;
    }
  }

  @override
  Future<void> revokeSession(
    String authRefreshToken, {
    String? authBaseUrl,
  }) async {
    if (authRefreshToken.isEmpty) return;
    final base = _normalizeBase(
      (authBaseUrl == null || authBaseUrl.isEmpty)
          ? (_authBaseUrl ?? '')
          : authBaseUrl,
    );
    if (base.isEmpty) {
      throw NekoApiException('缺少 NekoAuth 地址，无法注销登录会话');
    }
    final res = await _postJson(
      Uri.parse('$base/api/auth/logout'),
      cookies: {kNekoAuthRefreshCookie: authRefreshToken},
    );
    // 204 = 成功；401 = 会话本来就已经失效（视为成功）；其余按失败上报。
    if (res.status >= 400 && res.status != 401) {
      throw NekoApiException(
        _messageOf(res.json) ?? '注销登录会话失败（HTTP ${res.status}）',
        statusCode: res.status,
      );
    }
  }

  // ── 链路步骤 ──────────────────────────────────────────────────

  /// 步骤 1：让 NekoMusic 后端生成一次性授权会话，并解析出 NekoAuth 地址。
  Future<_SsoStart> _startSso({required bool silent}) async {
    final res = await _postJson(
      _musicUri('/api/user/sso/start'),
      body: {'client': kNekoAuthSsoClient, 'returnTo': '/', 'silent': silent},
    );
    _ensureOk(res, fallback: '无法发起登录');
    if (res.json?['success'] != true) {
      throw NekoApiException(_messageOf(res.json) ?? '无法发起登录');
    }
    final data = res.json?['data'];
    final url = data is Map ? _stringOf(data['url']) : '';
    final authorize = Uri.tryParse(url);
    if (authorize == null || !authorize.hasScheme || authorize.host.isEmpty) {
      throw NekoApiException('登录服务返回的授权地址无效');
    }
    _authBaseUrl = _normalizeBase(
      '${authorize.scheme}://${authorize.authority}',
    );
    final params = authorize.queryParameters;
    for (final key in const [
      'client_id',
      'redirect_uri',
      'response_type',
      'state',
      'code_challenge',
    ]) {
      if (_stringOf(params[key]).isEmpty) {
        throw NekoApiException('授权地址缺少参数：$key');
      }
    }
    return _SsoStart(
      // 原样保留 query（含 state / nonce / PKCE），只把路径换成 JSON 接口。
      authorizeUri: Uri.parse(
        '$_authBaseUrl/api/oauth/authorize?${authorize.query}',
      ),
      params: params,
    );
  }

  /// 步骤 3~5：授权 → 回调取 handoff → 领取 token。
  Future<NekoAuthSession> _authorizeAndClaim(
    _SsoStart sso,
    String authAccessToken,
    String authRefreshToken,
  ) async {
    final authz = await _getJson(
      sso.authorizeUri,
      bearer: authAccessToken,
    );
    _ensureOk(authz, fallback: '授权请求失败');
    var redirect = _stringOf(authz.json?['redirectUrl']);
    if (redirect.isEmpty) {
      // 第一方自动同意不可用（例如部署未配置父域 Cookie）：显式同意。
      // scope 由 NekoMusic 自己在 start 里申请（openid/profile/email/roles），
      // 用户点「登录」即表示同意这些最小范围。
      redirect = await _decide(sso, authAccessToken);
    }
    final handoff = await _handoffOf(redirect);
    final claim = await _postJson(
      _musicUri('/api/user/sso/claim'),
      body: {'handoff': handoff},
    );
    _ensureOk(claim, fallback: '登录失败');
    if (claim.json?['success'] != true) {
      throw NekoApiException(_messageOf(claim.json) ?? '登录失败');
    }
    final data = claim.json?['data'];
    if (data is! Map) {
      throw NekoApiException('登录响应格式异常');
    }
    final token = _stringOf(data['token']);
    if (token.isEmpty) {
      throw NekoApiException('登录响应缺少登录令牌');
    }
    final rawUser = data['user'];
    return NekoAuthSession(
      token: token,
      authRefreshToken: authRefreshToken,
      user: rawUser is Map
          ? NekoUser.fromJson(Map<String, dynamic>.from(rawUser))
          : null,
      expiresAt: jwtExpiry(token),
      authBaseUrl: _authBaseUrl,
    );
  }

  /// 显式同意（仅在第一方自动同意不可用时使用）。
  Future<String> _decide(_SsoStart sso, String bearer) async {
    final p = sso.params;
    final res = await _postJson(
      _authUri('/api/oauth/authorize/decision'),
      bearer: bearer,
      body: {
        'clientId': _stringOf(p['client_id']),
        'redirectUri': _stringOf(p['redirect_uri']),
        'responseType': _stringOf(p['response_type']),
        'scope': _stringOf(p['scope']),
        'state': ?p['state'],
        'nonce': ?p['nonce'],
        'codeChallenge': ?p['code_challenge'],
        'codeChallengeMethod': ?p['code_challenge_method'],
        'approved': true,
      },
    );
    _ensureOk(res, fallback: '授权确认失败');
    final redirect = _stringOf(res.json?['redirectUrl']);
    if (redirect.isEmpty) {
      throw NekoApiException(_messageOf(res.json) ?? '授权确认失败');
    }
    return redirect;
  }

  /// 步骤 4：请求回调地址但**不跟随**重定向，只解析 `handoff`。
  Future<String> _handoffOf(String redirectUrl) async {
    final uri = Uri.tryParse(redirectUrl);
    if (uri == null || !uri.hasScheme) {
      throw NekoApiException('登录服务返回的回调地址无效');
    }
    final res = await _send('GET', uri, followRedirects: false);
    final location = res.location;
    if (location.isEmpty) {
      // 回调本身失败时直接返回 JSON 错误体（没有 Location）。
      throw NekoApiException(
        _messageOf(res.json) ?? '授权回调失败（HTTP ${res.status}）',
        statusCode: res.status,
      );
    }
    final target = Uri.parse(uri.resolve(location).toString());
    final handoff = _stringOf(target.queryParameters['handoff']);
    if (handoff.isEmpty) {
      throw NekoApiException('授权回调缺少一次性登录交接');
    }
    return handoff;
  }

  // ── HTTP ─────────────────────────────────────────────────────

  Uri _musicUri(String path) => Uri.parse('$_musicBaseUrl$path');

  Uri _authUri(String path, {Map<String, String>? query}) {
    final base = _authBaseUrl;
    if (base == null) {
      throw NekoApiException('尚未取得 NekoAuth 地址，请重新登录');
    }
    final uri = Uri.parse('$base$path');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: query);
  }

  Future<_AuthResponse> _getJson(Uri uri, {String? bearer}) =>
      _send('GET', uri, bearer: bearer);

  Future<_AuthResponse> _postJson(
    Uri uri, {
    Object? body,
    String? bearer,
    Map<String, String>? cookies,
  }) => _send(
    'POST',
    uri,
    body: body,
    bearer: bearer,
    cookies: cookies,
  );

  Future<_AuthResponse> _send(
    String method,
    Uri uri, {
    Object? body,
    String? bearer,
    Map<String, String>? cookies,
    bool followRedirects = true,
  }) async {
    final bodyBytes = body == null
        ? const <int>[]
        : utf8.encode(jsonEncode(body));
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.openUrl(method, uri).timeout(timeout);
      req.followRedirects = followRedirects;
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      nekoRequestHeaders.forEach(req.headers.set);
      if (bearer != null && bearer.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      if (cookies != null && cookies.isNotEmpty) {
        req.headers.set(
          HttpHeaders.cookieHeader,
          cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
        );
      }
      if (bodyBytes.isNotEmpty) {
        req.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/json; charset=utf-8',
        );
        req.add(bodyBytes);
      }
      final res = await req.close().timeout(timeout);
      final bytes = await res
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
          .timeout(timeout);
      final text = utf8.decode(bytes, allowMalformed: true);
      Map<String, dynamic>? decoded;
      if (text.trim().isNotEmpty) {
        try {
          final json = jsonDecode(text);
          if (json is Map<String, dynamic>) decoded = json;
        } catch (_) {
          // 非 JSON（如代理错误页）：交给状态码处理
        }
      }
      return _AuthResponse(
        status: res.statusCode,
        json: decoded,
        location: res.headers.value(HttpHeaders.locationHeader) ?? '',
        cookies: _cookiesOf(res),
      );
    } on TimeoutException {
      throw NekoApiException('登录请求超时', kind: NekoErrorKind.network);
    } on SocketException catch (e) {
      throw NekoApiException(
        '网络不可达：${e.message}',
        kind: NekoErrorKind.network,
      );
    } catch (e) {
      if (e is NekoApiException) rethrow;
      throw NekoApiException('$e', kind: NekoErrorKind.network);
    } finally {
      client.close(force: true);
    }
  }

  /// 解析 `Set-Cookie`。
  ///
  /// NekoAuth 登录会同时下发两个同名 Cookie：真实值（Path=/）与用于清理
  /// 旧路径的**空值**（Path=/api/auth）。因此必须忽略空值，否则会把刷新
  /// 令牌解析成空串、导致无法静默续期。
  static Map<String, String> _cookiesOf(HttpClientResponse res) {
    final out = <String, String>{};
    for (final raw in res.headers[HttpHeaders.setCookieHeader] ?? const []) {
      final semi = raw.indexOf(';');
      final pair = (semi < 0 ? raw : raw.substring(0, semi)).trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      out[name] = value;
    }
    return out;
  }

  static String _cookieValue(Map<String, String> cookies, String name) =>
      cookies[name] ?? '';

  void _ensureOk(_AuthResponse res, {required String fallback}) {
    if (res.status >= 200 && res.status < 300) return;
    throw NekoApiException(
      _messageOf(res.json) ?? '$fallback（HTTP ${res.status}）',
      statusCode: res.status,
      kind: NekoErrorKind.api,
    );
  }

  /// 取服务端错误文案（`message` / OAuth `error_description` / `error`）。
  static String? _messageOf(Map<String, dynamic>? json) {
    for (final key in const ['message', 'error_description', 'error']) {
      final value = _stringOf(json?[key]);
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  static String _stringOf(Object? value) => value?.toString().trim() ?? '';

  static String _normalizeBase(String raw) {
    var value = raw.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// 如实上报设备画像（服务端据此在「登录设备」里展示）。
  static Map<String, dynamic> _deviceProfile() {
    final platform = Platform.operatingSystem;
    final version = Platform.operatingSystemVersion.trim();
    return {
      'type': 'desktop',
      'platform': platform,
      if (version.isNotEmpty)
        'platformVersion': version.length > 40
            ? version.substring(0, 40)
            : version,
      'source': 'app',
    };
  }

  /// 本地解析 JWT 的 `exp`（不验签，仅用于决定何时续期）。
  static DateTime? jwtExpiry(String token) {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    try {
      final payload = base64Url.normalize(parts[1]);
      final decoded = jsonDecode(utf8.decode(base64Url.decode(payload)));
      if (decoded is! Map) return null;
      final exp = decoded['exp'];
      if (exp is num) {
        return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000);
      }
    } catch (_) {
      // 非 JWT / 非法载荷：不提供过期时间（调用方按需续期）
    }
    return null;
  }
}

/// 一次性 SSO 授权会话（`/api/user/sso/start` 的返回值）。
class _SsoStart {
  const _SsoStart({required this.authorizeUri, required this.params});

  /// NekoAuth 的 JSON 授权接口地址（query 与 start 原样一致）。
  final Uri authorizeUri;

  /// start 返回的授权参数（decision 回退时要用解码后的值）。
  final Map<String, String> params;
}

/// 单次 HTTP 结果（状态码 + JSON + Location + Set-Cookie）。
class _AuthResponse {
  const _AuthResponse({
    required this.status,
    required this.json,
    required this.location,
    required this.cookies,
  });

  final int status;
  final Map<String, dynamic>? json;
  final String location;
  final Map<String, String> cookies;
}
