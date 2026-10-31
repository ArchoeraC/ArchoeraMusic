// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// NekoMusic **客户端实例身份**（`neko-client-v1`）。
///
/// 背景：NekoMusic 服务端已对第三方客户端强制「公开 client_id + 每安装实例
/// EC P-256 私钥 + 短期令牌 + 每请求 ECDSA 签名」的客户端身份校验，仅靠
/// `User-Agent` 形状已无法通过（见 `CrawlerProtectionFilter` /
/// `ClientIdentityFilter`）。本模块按官方 PC 端的协议实现该身份链路：
///
/// 1. `GET  /api/client/challenge?client_id=&platform=&purpose=register|token`
///    换一次性挑战（绑定 client_id / 平台 / 来源 IP / User-Agent，5 分钟有效）；
/// 2. `POST /api/client/register`（首次）或 `POST /api/client/token`（续签），
///    用实例私钥对规范化串做 `SHA256withECDSA`（DER + base64url），换取
///    `{instance_id, token, expires_at}`；
/// 3. 受保护请求逐次签名：`neko-client-v1\n方法\n路径\n查询串\nclient_id\n
///    instance_id\n平台\n时间戳\n请求体 SHA-256(hex)\nnonce`，随请求附带
///    `X-Neko-Client-{Id,Instance,Token,Timestamp,Signature}`；
/// 4. 服务端回 `401 + X-Neko-Client-Status: invalid` 时作废本地令牌、重新注册
///    （注册仍被拒则轮换密钥）后重试一次。
///
/// 平台取 `pc`、client_id 取官方公开的 PC 应用标识，与
/// `ClientRegistryDatabaseManager.OFFICIAL_PC`（公开、非机密、免证明）一致；
/// 每个安装实例仍持有**自己的**私钥与实例 ID，服务端据此单独审计与吊销。
/// 私钥只落在本机（原生 `apl_file_write_atomic` 的 0600 原子写），不出现在任何
/// 请求体或日志里；`client_id` 本身是公开标识，单独泄露无法伪造请求。
///
/// 协议事实来源：NekoMusicForPc `src/core/clientidentity.cpp`、
/// `src/core/nekonetworkaccessmanager.cpp`（仅参考协议字段与签名串构造，
/// 代码为独立 Dart 实现）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pointycastle/export.dart';

import '../../apis/neko/neko_client_config.dart';
import '../../stores/data_dir.dart';
import '../../utils/safe_file.dart';
import 'neko_identity.dart';

/// 协议版本（签名串首行；服务端 `ClientIdentityProtocol.PROTOCOL_VERSION`）。
const String kNekoIdentityProtocol = 'neko-client-v1';

/// 客户端身份平台：必须与服务端登记的 client_id 平台一致（`pc`）。
const String kNekoIdentityPlatform = 'pc';

/// 实例令牌请求头前缀。
const String kNekoClientIdHeader = 'X-Neko-Client-Id';
const String kNekoClientInstanceHeader = 'X-Neko-Client-Instance';
const String kNekoClientTokenHeader = 'X-Neko-Client-Token';
const String kNekoClientTimestampHeader = 'X-Neko-Client-Timestamp';
const String kNekoClientSignatureHeader = 'X-Neko-Client-Signature';

/// 身份失效标记响应头（`invalid` → 重新注册后重试）。
const String kNekoClientStatusHeader = 'X-Neko-Client-Status';

/// 客户端身份相关异常（由 `NekoClient` 转译成 `NekoApiException`）。
class NekoIdentityException implements Exception {
  NekoIdentityException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 站点未提供客户端身份接口（404 / 405）：旧版或自建服务端，降级为不带身份请求。
///
/// 新服务端缺少身份会直接 401，因此「跳过」只会让旧服务端保持原有行为。
class _IdentityUnsupported implements Exception {
  const _IdentityUnsupported();
}

/// 请求签名串（`neko-client-v1`）。客户端与服务端必须**逐字节一致**。
///
/// 字段顺序固定：协议版本、方法（大写）、路径（解码后）、查询串（原始编码）、
/// client_id、instance_id、平台、Unix 秒时间戳、请求体 SHA-256（hex；流式上传
/// 为 `-`）、nonce（无则空串）。
@visibleForTesting
String nekoCanonicalRequest({
  required String method,
  required String path,
  required String query,
  required String clientId,
  required String instanceId,
  required String platform,
  required int timestampSeconds,
  required String bodyHash,
  required String nonce,
}) =>
    <String>[
      kNekoIdentityProtocol,
      method.toUpperCase(),
      path,
      query,
      clientId,
      instanceId,
      platform,
      '$timestampSeconds',
      bodyHash,
      nonce,
    ].join('\n');

/// 一个安装实例在某个站点上的身份凭据。
class NekoInstanceCredentials {
  const NekoInstanceCredentials({
    required this.instanceId,
    required this.token,
    required this.expiresAtSeconds,
  });

  final String instanceId;
  final String token;

  /// 令牌过期时刻（Unix 秒）。
  final int expiresAtSeconds;
}

/// 站点级实例身份：注册 / 续签 / 每请求签名。
///
/// 按站点根地址缓存（同一服务器复用同一实例），跨启动持久化到数据目录。
class NekoInstanceIdentity {
  NekoInstanceIdentity._(this.baseUrl);

  /// 按归一化站点地址取实例（同址复用，避免并发登记出多个实例）。
  static NekoInstanceIdentity forBaseUrl(String baseUrl) =>
      _pool.putIfAbsent(baseUrl, () => NekoInstanceIdentity._(baseUrl));

  static final Map<String, NekoInstanceIdentity> _pool = {};

  /// 测试注入：覆盖身份持久化文件路径（生产走应用数据目录）。
  @visibleForTesting
  static String? debugStorePath;

  /// 测试注入：清空站点实例缓存。
  @visibleForTesting
  static void debugClearPool() => _pool.clear();

  /// 测试注入：覆盖 client_id（生产走构建期 `NEKO_CLIENT_ID`）。
  @visibleForTesting
  static String? debugClientId;

  /// 当前生效的 client_id（未配置为空串 → 本源禁用）。
  String get _clientId => debugClientId ?? kNekoClientId;

  /// 本源是否具备自有客户端身份（未注入 `NEKO_CLIENT_ID` 时为 false）。
  static bool get configured =>
      debugClientId != null || nekoClientIdentityConfigured;

  /// 连续被服务端判定身份无效的次数上限：超过即熔断，停止重注册（防打服务端）。
  static const int _maxConsecutiveRejections = 3;

  int _consecutiveRejections = 0;
  bool _blocked = false;
  String? _blockedReason;

  /// 是否已熔断（客户端登记被停用 / 过期 / 密钥被拒等长期失败）。
  bool get blocked => _blocked;

  /// 熔断原因（UI / 日志展示用）。
  String? get blockedReason => _blockedReason;

  /// 任一次签名请求被服务端接受：清零连续拒绝计数。
  void noteServerAcceptance() {
    _consecutiveRejections = 0;
  }

  /// 服务端再次判定身份无效：累计到上限后熔断，不再反复注册。
  void noteServerRejection(String reason) {
    if (_blocked) return;
    _consecutiveRejections++;
    if (_consecutiveRejections >= _maxConsecutiveRejections) {
      _blocked = true;
      _blockedReason = reason;
    }
  }

  final String baseUrl;

  static const Duration _timeout = Duration(seconds: 15);

  /// 提前续签窗口：令牌剩余寿命不足 24h 即续签（对齐官方 PC 端）。
  static const int _refreshAheadSeconds = 24 * 60 * 60;

  /// 续签失败时的兜底窗口：令牌仍有 5 分钟以上则继续用旧令牌。
  static const int _fallbackSeconds = 5 * 60;

  _IdentityEntry? _entry;
  Future<_IdentityEntry>? _inflight;
  bool _forceRefresh = false;

  /// 站点不支持客户端身份（旧服务端）：后续请求不再尝试，直接按无身份发送。
  bool _unsupported = false;

  /// 为一次受保护请求生成实例身份头。
  ///
  /// [body] 为**即将发送的原始请求体字节**（签名覆盖其 SHA-256）；[nonce] 为本次
  /// 请求携带的防重放 nonce（无则按空串参与签名）。
  ///
  /// 站点没有客户端身份接口（旧服务端）时返回空表，调用方按原样发送。
  Future<Map<String, String>> signHeaders({
    required String method,
    required Uri uri,
    required List<int> body,
    String? nonce,
  }) async {
    if (_clientId.isEmpty) {
      throw NekoIdentityException(
        '未配置 NekoMusic 客户端标识（构建时请传 --dart-define=NEKO_CLIENT_ID=…）',
      );
    }
    if (_blocked) {
      throw NekoIdentityException(
        'NekoMusic 客户端身份已停用${_blockedReason == null ? '' : '：$_blockedReason'}',
      );
    }
    if (_unsupported) return const {};
    final _IdentityEntry entry;
    try {
      entry = await _ensure();
    } on _IdentityUnsupported {
      _unsupported = true;
      return const {};
    }
    final timestamp = _nowSeconds;
    final canonical = nekoCanonicalRequest(
      method: method,
      path: _signingPath(uri),
      query: uri.query,
      clientId: _clientId,
      instanceId: entry.credentials.instanceId,
      platform: kNekoIdentityPlatform,
      timestampSeconds: timestamp,
      bodyHash: _sha256Hex(body),
      nonce: nonce ?? '',
    );
    return {
      kNekoClientIdHeader: _clientId,
      kNekoClientInstanceHeader: entry.credentials.instanceId,
      kNekoClientTokenHeader: entry.credentials.token,
      kNekoClientTimestampHeader: '$timestamp',
      kNekoClientSignatureHeader: entry.key.signBase64Url(canonical),
    };
  }

  /// 服务端判定实例身份失效：作废内存凭据，下次 [signHeaders] 强制续签 / 重注册。
  Future<void> invalidate() async {
    _entry = null;
    _inflight = null;
    _forceRefresh = true;
  }

  /// 丢弃站点身份（设置里切换服务器 / 手动清理时使用）。
  Future<void> reset() async {
    _entry = null;
    _inflight = null;
    _forceRefresh = false;
    _unsupported = false;
    _blocked = false;
    _blockedReason = null;
    _consecutiveRejections = 0;
    try {
      final file = File(_storePath);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // 清理失败不影响下次重新注册
    }
  }

  // ── 身份加载 ─────────────────────────────────────────────────

  Future<_IdentityEntry> _ensure() {
    final cached = _entry;
    if (cached != null &&
        !_forceRefresh &&
        cached.credentials.expiresAtSeconds >
            _nowSeconds + _refreshAheadSeconds) {
      return Future.value(cached);
    }
    final pending = _inflight;
    if (pending != null) return pending;
    final future = _load(force: _forceRefresh);
    _inflight = future;
    return future.then((entry) {
      _entry = entry;
      _forceRefresh = false;
      return entry;
    }).whenComplete(() {
      _inflight = null;
    });
  }

  Future<_IdentityEntry> _load({required bool force}) async {
    final stored = _readStore();
    var key = stored?['d'] is String
        ? _EcdsaKey.fromPrivateHex(stored!['d'] as String)
        : null;
    key ??= _EcdsaKey.generate();
    final instanceId = stored?['instanceId'] as String? ?? '';
    final token = stored?['token'] as String? ?? '';
    final expiresAt = (stored?['expiresAt'] as num?)?.toInt() ?? 0;
    final now = _nowSeconds;

    if (!force &&
        instanceId.isNotEmpty &&
        expiresAt > now + _refreshAheadSeconds) {
      return _IdentityEntry(
        key,
        NekoInstanceCredentials(
          instanceId: instanceId,
          token: token,
          expiresAtSeconds: expiresAt,
        ),
      );
    }

    if (instanceId.isNotEmpty) {
      final refreshed = await _requestToken(key, instanceId);
      if (refreshed != null) {
        _writeStore(key, refreshed);
        return _IdentityEntry(key, refreshed);
      }
      // 续签失败但旧令牌尚未临近过期：先继续用，避免网络抖动导致音源不可用。
      if (!force && token.isNotEmpty && expiresAt > now + _fallbackSeconds) {
        return _IdentityEntry(
          key,
          NekoInstanceCredentials(
            instanceId: instanceId,
            token: token,
            expiresAtSeconds: expiresAt,
          ),
        );
      }
    }

    final registered = await _register(key, allowRotate: true);
    _writeStore(registered.key, registered.credentials);
    return registered;
  }

  /// 续签短期令牌；服务端明确拒绝（401）或响应不合法时返回 null。
  Future<NekoInstanceCredentials?> _requestToken(
    _EcdsaKey key,
    String instanceId,
  ) async {
    try {
      final challenge = await _fetchChallenge('token');
      final timestamp = _nowSeconds;
      final canonical = <String>[
        'neko-client-token-v1',
        _clientId,
        kNekoIdentityPlatform,
        instanceId,
        challenge,
        '$timestamp',
      ].join('\n');
      final res = await _jsonRequest(
        'POST',
        _endpoint('/api/client/token'),
        body: {
          'client_id': _clientId,
          'platform': kNekoIdentityPlatform,
          'instance_id': instanceId,
          'challenge': challenge,
          'timestamp': timestamp,
          'signature': key.signBase64Url(canonical),
        },
      );
      return _parseIssued(res, expectInstance: instanceId);
    } on NekoIdentityException {
      return null;
    }
  }

  /// 注册新实例；注册被拒（401）时轮换密钥重试一次。
  Future<_IdentityEntry> _register(
    _EcdsaKey key, {
    required bool allowRotate,
  }) async {
    final challenge = await _fetchChallenge('register');
    final instanceId = _uuidV4();
    final timestamp = _nowSeconds;
    final publicKey = key.spkiBase64Url;
    final canonical = <String>[
      'neko-client-register-v1',
      _clientId,
      kNekoIdentityPlatform,
      instanceId,
      publicKey,
      challenge,
      '$timestamp',
    ].join('\n');
    final res = await _jsonRequest(
      'POST',
      _endpoint('/api/client/register'),
      body: {
        'client_id': _clientId,
        'platform': kNekoIdentityPlatform,
        'instance_id': instanceId,
        'public_key': publicKey,
        'challenge': challenge,
        'timestamp': timestamp,
        'signature': key.signBase64Url(canonical),
      },
    );
    if (res.status == 401 && allowRotate) {
      // 公钥被服务端明确拒绝：换新密钥重新登记一次。
      final rotated = _EcdsaKey.generate();
      return _register(rotated, allowRotate: false);
    }
    final credentials = _parseIssued(res, expectInstance: instanceId);
    if (credentials == null) {
      final message = _errorMessage(res, '客户端实例注册失败');
      // 401/403：client_id 被停用 / 过期 / 公钥被拒——计入熔断，避免反复注册。
      if (res.status == 401 || res.status == 403) {
        noteServerRejection(message);
      }
      throw NekoIdentityException(message);
    }
    return _IdentityEntry(key, credentials);
  }

  Future<String> _fetchChallenge(String purpose) async {
    final uri = _endpoint('/api/client/challenge').replace(
      queryParameters: {
        'client_id': _clientId,
        'platform': kNekoIdentityPlatform,
        'purpose': purpose,
      },
    );
    final res = await _jsonRequest('GET', uri);
    if (res.status == 404 || res.status == 405) {
      throw const _IdentityUnsupported();
    }
    final data = res.json?['data'];
    final protocol = data is Map ? data['protocol']?.toString() : null;
    final challenge = data is Map ? data['challenge']?.toString() : null;
    if (res.status < 200 ||
        res.status >= 300 ||
        protocol != kNekoIdentityProtocol ||
        challenge == null ||
        challenge.isEmpty) {
      throw NekoIdentityException(
        _errorMessage(res, '获取客户端身份挑战失败'),
      );
    }
    return challenge;
  }

  /// 解析 `{success, data:{instance_id, token, expires_at}}`。
  NekoInstanceCredentials? _parseIssued(
    _HttpJson res, {
    required String expectInstance,
  }) {
    if (res.status < 200 || res.status >= 300) return null;
    final root = res.json;
    if (root == null || root['success'] != true) return null;
    final data = root['data'];
    if (data is! Map) return null;
    final instanceId = data['instance_id']?.toString() ?? '';
    final token = data['token']?.toString() ?? '';
    final expiresAt = (data['expires_at'] as num?)?.toInt() ?? 0;
    if (instanceId != expectInstance || token.isEmpty || expiresAt <= 0) {
      return null;
    }
    return NekoInstanceCredentials(
      instanceId: instanceId,
      token: token,
      expiresAtSeconds: expiresAt,
    );
  }

  String _errorMessage(_HttpJson res, String fallback) {
    final message = res.json?['message']?.toString();
    if (message != null && message.isNotEmpty) return message;
    return '$fallback（HTTP ${res.status}）';
  }

  Uri _endpoint(String path) => Uri.parse('$baseUrl$path');

  // ── HTTP（自举接口本身豁免身份 / 防重放）────────────────────────

  Future<_HttpJson> _jsonRequest(
    String method,
    Uri uri, {
    Object? body,
  }) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client.openUrl(method, uri).timeout(_timeout);
      nekoRequestHeaders.forEach(req.headers.set);
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        req.headers.set(HttpHeaders.contentLengthHeader, '${bytes.length}');
        req.add(bytes);
      }
      final res = await req.close().timeout(_timeout);
      final bytes = await res
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
          .timeout(_timeout);
      final text = utf8.decode(bytes, allowMalformed: true);
      Map<String, dynamic>? json;
      if (text.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(text);
          if (decoded is Map<String, dynamic>) json = decoded;
        } catch (_) {
          // 非 JSON（错误页 / HTML）：只看状态码
        }
      }
      return _HttpJson(res.statusCode, json);
    } on TimeoutException {
      throw NekoIdentityException('客户端身份请求超时');
    } on SocketException catch (e) {
      throw NekoIdentityException('网络不可达：${e.message}');
    } on NekoIdentityException {
      rethrow;
    } catch (e) {
      throw NekoIdentityException('客户端身份请求失败：$e');
    } finally {
      client.close(force: true);
    }
  }

  // ── 持久化（每个站点一条；私钥写走原生 0600 原子写）─────────────

  String get _storePath =>
      debugStorePath ?? '${resolveDataDir()}/neko_client_identity.json';

  Map<String, dynamic>? _readStore() {
    try {
      final text = SafeFile.readString(_storePath);
      if (text == null) return null;
      final root = jsonDecode(text);
      if (root is! Map) return null;
      final stores = root['stores'];
      if (stores is! Map) return null;
      final entry = stores[baseUrl];
      if (entry is! Map) return null;
      return entry.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  void _writeStore(_EcdsaKey key, NekoInstanceCredentials credentials) {
    try {
      Map<String, dynamic> root = {};
      final text = SafeFile.readString(_storePath);
      if (text != null) {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) root = decoded;
      }
      final stores = root['stores'];
      final map = stores is Map<String, dynamic>
          ? stores
          : <String, dynamic>{};
      map[baseUrl] = {
        'd': key.privateHex,
        'instanceId': credentials.instanceId,
        'token': credentials.token,
        'expiresAt': credentials.expiresAtSeconds,
      };
      root['stores'] = map;
      SafeFile.writeAtomicString(_storePath, jsonEncode(root));
    } catch (_) {
      // 落盘失败只影响下次启动的复用，不阻断本次请求
    }
  }
}

class _IdentityEntry {
  const _IdentityEntry(this.key, this.credentials);

  final _EcdsaKey key;
  final NekoInstanceCredentials credentials;
}

class _HttpJson {
  const _HttpJson(this.status, this.json);

  final int status;
  final Map<String, dynamic>? json;
}

int get _nowSeconds => DateTime.now().millisecondsSinceEpoch ~/ 1000;

String _sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

/// 签名用的路径：服务端按路由的**解码后**路径签名（`RequestPath.of`）。
String _signingPath(Uri uri) {
  final path = uri.path.isEmpty ? '/' : uri.path;
  if (!path.contains('%')) return path;
  try {
    return Uri.decodeComponent(path);
  } catch (_) {
    return path;
  }
}

String _uuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String _base64Url(List<int> bytes) =>
    base64UrlEncode(bytes).replaceAll('=', '');

// ── EC P-256 实例密钥 ───────────────────────────────────────────

/// P-256 SubjectPublicKeyInfo 头部（后接 65 字节 X9.63 公钥点）。
const List<int> _kSpkiPrefix = [
  0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
  0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
  0x42, 0x00,
];

class _EcdsaKey {
  _EcdsaKey._(this._d, this._domain, this.spkiBase64Url);

  final BigInt _d;
  final ECDomainParameters _domain;

  /// SPKI DER 的 base64url（注册时提交给服务端）。
  final String spkiBase64Url;

  static _EcdsaKey generate() {
    final curve = ECCurve_prime256v1();
    final generator = ECKeyGenerator()
      ..init(
        ParametersWithRandom(
          ECKeyGeneratorParameters(curve),
          _secureRandom(),
        ),
      );
    final pair = generator.generateKeyPair();
    final privateKey = pair.privateKey;
    final publicKey = pair.publicKey;
    return _EcdsaKey._(
      privateKey.d!,
      curve,
      _spkiBase64Url(publicKey.Q!.getEncoded(false)),
    );
  }

  static _EcdsaKey? fromPrivateHex(String hex) {
    try {
      final d = BigInt.parse(hex, radix: 16);
      if (d <= BigInt.zero) return null;
      final curve = ECCurve_prime256v1();
      final point = curve.G * d;
      if (point == null || point.isInfinity) return null;
      return _EcdsaKey._(d, curve, _spkiBase64Url(point.getEncoded(false)));
    } catch (_) {
      return null;
    }
  }

  String get privateHex => _d.toRadixString(16);

  /// `SHA256withECDSA`（DER 签名，base64url 无填充）。
  String signBase64Url(String canonical) {
    final signer = ECDSASigner(SHA256Digest(), HMac.withDigest(SHA256Digest()));
    signer.init(
      true,
      PrivateKeyParameter<ECPrivateKey>(ECPrivateKey(_d, _domain)),
    );
    final signature = signer.generateSignature(
      Uint8List.fromList(utf8.encode(canonical)),
    ) as ECSignature;
    return _base64Url(_derSignature(signature.r, signature.s));
  }
}

String _spkiBase64Url(Uint8List rawPoint) {
  final out = Uint8List(_kSpkiPrefix.length + rawPoint.length)
    ..setAll(0, _kSpkiPrefix)
    ..setAll(_kSpkiPrefix.length, rawPoint);
  return _base64Url(out);
}

Uint8List _derSignature(BigInt r, BigInt s) {
  final body = <int>[..._derInteger(r), ..._derInteger(s)];
  return Uint8List.fromList([0x30, ..._derLength(body.length), ...body]);
}

List<int> _derInteger(BigInt value) {
  var bytes = _bigIntBytes(value);
  if (bytes.isEmpty) bytes = [0];
  if ((bytes.first & 0x80) != 0) bytes = [0, ...bytes];
  return [0x02, ..._derLength(bytes.length), ...bytes];
}

List<int> _derLength(int length) {
  if (length < 0x80) return [length];
  final bytes = <int>[];
  var value = length;
  while (value > 0) {
    bytes.insert(0, value & 0xff);
    value >>= 8;
  }
  return [0x80 | bytes.length, ...bytes];
}

List<int> _bigIntBytes(BigInt value) {
  final hex = value.toRadixString(16);
  final padded = hex.length.isOdd ? '0$hex' : hex;
  return [
    for (var i = 0; i < padded.length; i += 2)
      int.parse(padded.substring(i, i + 2), radix: 16),
  ];
}

FortunaRandom _secureRandom() {
  final random = Random.secure();
  final seed = Uint8List.fromList(
    List<int>.generate(32, (_) => random.nextInt(256)),
  );
  return FortunaRandom()..seed(KeyParameter(seed));
}
