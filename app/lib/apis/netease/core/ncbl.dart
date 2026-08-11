/// NCBL 加密日志上报（Dart 移植）——对齐 apis/netease/core/ncbl.ts。
///
/// 用于 scrobble_v1 听歌打卡：ChaCha20 加密 + RSA 包装会话密钥 + zstd 压缩分帧，
/// multipart 上传到 clientlog3。TS 侧 zstd 依赖 Node 运行时能力（缺省即报错），
/// Dart 侧同样通过 [_zstdCompress] hook 注入（默认抛错，与 TS 行为一致）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'config.dart';

/// NCBL 上下文（对齐 NcblContext）
class NcblContext {
  NcblContext({
    required this.app,
    required this.device,
    required this.auth,
    required this.startTime,
    required this.processId,
  });

  final Map<String, String> app;
  final Map<String, String> device;
  final Map<String, String> auth;
  final int startTime;
  final int processId;
}

class NcblUploadResult {
  NcblUploadResult({
    required this.success,
    required this.fileName,
    required this.payload,
    required this.respBody,
  });

  final bool success;
  final String fileName;
  final Uint8List payload;
  final Map<String, dynamic> respBody;
}

/// zstd 压缩 hook（由宿主注入；默认抛错，对齐 TS「缺 zstd 直接报错」）
typedef ZstdCompressFn = Uint8List Function(Uint8List input);

ZstdCompressFn? _zstdCompress;
void nmSetZstdCompress(ZstdCompressFn fn) => _zstdCompress = fn;

Uint8List _compressBody(Uint8List buf) {
  final fn = _zstdCompress;
  if (fn == null) {
    throw UnsupportedError('当前运行时不支持 zstd，无法进行 NCBL 上报');
  }
  return fn(buf);
}

// ── 常量 ──────────────────────────────────────────────

const _sigma = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574];
final BigInt _rsaN = BigInt.parse('fd90bd466ff9bc8a3fec2fbcf263b90d5c564879fa5d7aab89b31c1d5cb4139d', radix: 16);
final BigInt _rsaE = BigInt.from(65537);
const _magic = 'NCBL';
const _ncblVersion = 3;
const _headerFixedLen = 70;
const _metaBlockType = 0x4343;
const _defaultMaxFrame = 0x8000;
const _fieldSep = '\x01';

// ── 小端读写 ──────────────────────────────────────────

int _readU16LE(Uint8List b, int off) => b[off] | (b[off + 1] << 8);

int _readU32LE(Uint8List b, int off) =>
    b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

void _writeU16LE(Uint8List b, int off, int v) {
  b[off] = v & 0xff;
  b[off + 1] = (v >> 8) & 0xff;
}

void _writeU32LE(Uint8List b, int off, int v) {
  b[off] = v & 0xff;
  b[off + 1] = (v >> 8) & 0xff;
  b[off + 2] = (v >> 16) & 0xff;
  b[off + 3] = (v >> 24) & 0xff;
}

// ── ChaCha20 ──────────────────────────────────────────

int _rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xffffffff;

void _quarterRound(List<int> s, int a, int b, int c, int d) {
  s[a] = (s[a] + s[b]) & 0xffffffff;
  s[d] = _rotl(s[d] ^ s[a], 16);
  s[c] = (s[c] + s[d]) & 0xffffffff;
  s[b] = _rotl(s[b] ^ s[c], 12);
  s[a] = (s[a] + s[b]) & 0xffffffff;
  s[d] = _rotl(s[d] ^ s[a], 8);
  s[c] = (s[c] + s[d]) & 0xffffffff;
  s[b] = _rotl(s[b] ^ s[c], 7);
}

Uint8List _chachaBlock(Uint8List key, int counter, Uint8List nonce) {
  final state = List<int>.filled(16, 0);
  state[0] = _sigma[0];
  state[1] = _sigma[1];
  state[2] = _sigma[2];
  state[3] = _sigma[3];
  for (var i = 0; i < 8; i++) {
    state[4 + i] = _readU32LE(key, i * 4);
  }
  state[12] = counter & 0xffffffff;
  state[13] = _readU32LE(nonce, 0);
  state[14] = _readU32LE(nonce, 4);
  state[15] = _readU32LE(nonce, 8);

  final work = List<int>.from(state);
  for (var i = 0; i < 10; i++) {
    _quarterRound(work, 0, 4, 8, 12);
    _quarterRound(work, 1, 5, 9, 13);
    _quarterRound(work, 2, 6, 10, 14);
    _quarterRound(work, 3, 7, 11, 15);
    _quarterRound(work, 0, 5, 10, 15);
    _quarterRound(work, 1, 6, 11, 12);
    _quarterRound(work, 2, 7, 8, 13);
    _quarterRound(work, 3, 4, 9, 14);
  }

  final out = Uint8List(64);
  for (var i = 0; i < 16; i++) {
    _writeU32LE(out, i * 4, (work[i] + state[i]) & 0xffffffff);
  }
  return out;
}

Uint8List _chacha20(Uint8List key, int counter, Uint8List nonce, Uint8List data) {
  final out = Uint8List(data.length);
  for (var off = 0; off < data.length; off += 64) {
    final ks = _chachaBlock(key, (counter + (off >> 6)) & 0xffffffff, nonce);
    final end = math.min(off + 64, data.length);
    for (var i = off; i < end; i++) {
      out[i] = data[i] ^ ks[i - off];
    }
  }
  return out;
}

// ── RSA 包装（对齐 rsaWrap） ──────────────────────────

Uint8List _bigToBe(BigInt n, int len) {
  final out = Uint8List(len);
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (n & BigInt.from(0xff)).toInt();
    n = n >> 8;
  }
  return out;
}

BigInt _beToBig(Uint8List buf) {
  var n = BigInt.zero;
  for (final b in buf) {
    n = (n << 8) | BigInt.from(b);
  }
  return n;
}

Uint8List nmRsaWrap(Uint8List keyA) => _bigToBe(_beToBig(keyA).modPow(_rsaE, _rsaN), 32);

// ── 加密主体（对齐 encryptNCBL） ───────────────────────

/// NCBL 整体加密：meta 与 body 分别加密，输出 header + metaBlock + frames
Uint8List nmEncryptNcbl(Uint8List meta, Uint8List body) {
  final rng = math.Random.secure();

  var keyA = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
  if (keyA[0] >= 0xa3) keyA[0] = 0xa2;
  final keyB = nmRsaWrap(keyA);

  final uuid = Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));
  uuid[6] = (uuid[6] & 0x0f) | 0x40;
  uuid[8] = (uuid[8] & 0x3f) | 0x80;
  final nonce = Uint8List.sublistView(uuid, 0, 12);
  final counter = _readU32LE(uuid, 12) >> 2;
  final baseSeq = _readU16LE(
      Uint8List.fromList(List.generate(2, (_) => rng.nextInt(256))), 0);

  final metaCipher = _chacha20(keyB, counter, nonce, meta);
  final metaHead = Uint8List(4);
  _writeU16LE(metaHead, 0, _metaBlockType);
  _writeU16LE(metaHead, 2, metaCipher.length);
  final metaBlock = Uint8List.fromList([...metaHead, ...metaCipher]);
  final headerLen = _headerFixedLen + metaBlock.length;
  final compressed = _compressBody(body);

  final frames = <Uint8List>[];
  var seq = baseSeq;
  var off = 0;
  while (off < compressed.length || off == 0) {
    final end = math.min(off + _defaultMaxFrame, compressed.length);
    final slice = Uint8List.sublistView(compressed, off, end);
    final cipher = _chacha20(keyA, counter, nonce, slice);
    final head = Uint8List(6);
    _writeU16LE(head, 0, cipher.length);
    _writeU32LE(head, 2, seq & 0xffffffff);
    frames.add(head);
    frames.add(cipher);
    seq++;
    if (compressed.isEmpty) break;
    off += _defaultMaxFrame;
  }

  final trailing = Uint8List.fromList([for (final f in frames) ...f]);
  final frameCount = seq - baseSeq;

  final header = Uint8List(_headerFixedLen);
  header.setAll(0, utf8.encode(_magic));
  _writeU32LE(header, 4, _ncblVersion);
  _writeU16LE(header, 8, headerLen);
  header.setAll(10, uuid);
  header.setAll(26, keyB);
  _writeU32LE(header, 58, baseSeq & 0xffffffff);
  _writeU32LE(header, 62, (baseSeq + frameCount - 1) & 0xffffffff);
  _writeU32LE(header, 66, trailing.length);

  return Uint8List.fromList([...header, ...metaBlock, ...trailing]);
}

// ── 记录构建 ──────────────────────────────────────────

/// 单条记录：time\x01action\x01json；多条直接拼接（对齐 buildRecords）
String nmBuildRecords(List<({int time, String action, Object data})> records) {
  final buf = StringBuffer();
  for (final r in records) {
    final json = r.data is String ? r.data as String : jsonEncode(r.data);
    buf.write('$r.time$_fieldSep$r.action$_fieldSep$json');
  }
  return buf.toString();
}

Map<String, dynamic> nmBuildPlv(
  NcblContext ctx,
  Map<String, dynamic> song,
  Map<String, dynamic> source,
) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {
    'mode': 'circulation',
    'download': 0,
    'alg': '',
    'status': 'front',
    'id': '${song['id']}',
    'bitrate': song['bitrate'],
    'type': 'song',
    'is_listentogether': 0,
    'source': source['name'],
    'is_heart': 0,
    'resource_ratio': '',
    'resource_time': song['time'],
    'musiceffect_id': '',
    'app_mode': 2,
    'bitrate_level': song['level'],
    '_addrefer':
        '[F:63][$now#933#${ctx.app['version']}#${ctx.app['versionCode']}#c9156c3][e][2][23][cell_pc_songlist_song:2|page_pc_songlist_songflow|page_mine_like_music][${song['id']}:song:x:x|:::|${source['id']}:list::]',
    '_multirefers': [
      '[F:26][s][18][_ai]',
      '[F:26][s][12][_ai]',
      '[F:63][$now#933#${ctx.app['version']}#${ctx.app['versionCode']}#c9156c3][e][2][8][cell_pc_main_tab_entrance:6|page_pc_main_tab][我喜欢的音乐:spm::|:::]',
      '[F:26][s][5][_ai]',
      '[F:26][s][0][_ai]',
    ],
    'vipType': ctx.auth['vipType'],
    'fee': 1,
    'file': 4,
    'rightSource': 0,
    'sourceId': source['id'],
    'sourcetype': source['type'],
    'libra_abt': '',
    'channel': ctx.app['channel'],
    'curStartChannel': '',
  };
}

Map<String, dynamic> nmBuildPld(
  NcblContext ctx,
  Map<String, dynamic> song,
  Map<String, dynamic> source,
  int played,
) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {
    'mode': 'circulation',
    'download': 0,
    'alg': '',
    'status': 'front',
    'id': '${song['id']}',
    'time': played,
    'type': 'song',
    'is_listentogether': 0,
    'source': source['name'],
    'is_heart': 0,
    'realtime': played,
    'resource_ratio': '',
    'resource_time': song['time'],
    'musiceffect_id': '1001',
    'app_mode': 1,
    'lyriceffect': 'default',
    'displayMode': 'classic',
    'bitrate': song['bitrate'],
    'bitrate_level': song['level'],
    '_addrefer':
        '[F:63][$now#616#${ctx.app['version']}#${ctx.app['versionCode']}#c9156c3][e][2][92][btn_pc_cover_play|cell_pc_songlist_song:6|page_pc_songlist_songflow|page_mine_like_music][:::|${song['id']}:song:x:x|:::|${source['id']}:list::]',
    '_multirefers': [
      '[F:26][s][87][_ai]',
      '[F:26][s][81][_ai]',
      '[F:26][s][75][_ai]',
      '[F:26][s][69][_ai]',
      '[F:26][s][63][_ai]',
    ],
    'vipType': ctx.auth['vipType'],
    'fee': 8,
    'file': 4,
    'rightSource': 0,
    'sourceId': source['id'],
    'sourcetype': source['type'],
    'end': 'interrupt',
    'libra_abt': '',
    'channel': ctx.app['channel'],
    'curStartChannel': '',
  };
}

// ── Cookie 解析与上下文提取 ────────────────────────────

Map<String, String> nmNcblParseCookie(Object? cookie) {
  if (cookie is Map) return cookie.map((k, v) => MapEntry('$k', '$v'));
  if (cookie is! String) return {};
  final obj = <String, String>{};
  for (final part in cookie.split(';')) {
    final idx = part.indexOf('=');
    if (idx <= 0) continue;
    final key = part.substring(0, idx).trim();
    final val = part.substring(idx + 1).trim();
    if (key.isNotEmpty) obj[key] = val;
  }
  return obj;
}

String _randomHexId() {
  final rng = math.Random.secure();
  return List.generate(16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

NcblContext nmNcblExtractContext(Map<String, String> c) {
  final rng = math.Random.secure();
  final fallbackCid = '${List.generate(3, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}.${DateTime.now().millisecondsSinceEpoch}.01.0';
  return NcblContext(
    app: {
      'id': c['appid'] ?? '',
      'urs': '',
      'pid': '',
      'nsm': c['WEVNSM'] ?? '1.0.0',
      'cid': c['WNMCID'] ?? fallbackCid,
      'channel': c['channel'] ?? 'netease',
      'version': c['appver'] ?? '3.1.35',
      'versionCode': c['versioncode'] ?? '205293',
      'buildCode': c['buildver'] ?? '',
      'buildType': 'release',
      'packageId': '',
    },
    device: {
      'id': c['deviceId'] ?? c['sDeviceId'] ?? '',
      'ti': c['NMTID'] ?? '',
      'sign': c['clientSign'] ?? '',
      'model': c['mode'] ?? c['mobilename'] ?? '',
      'nnid': c['_ntes_nnid'] ?? ',',
      'nuid': c['_ntes_nuid'] ?? '',
      'csrf': c['__csrf'] ?? '',
      'systemType': c['os'] ?? 'pc',
      'systemVersion':
          c['osver'] ?? 'Microsoft-Windows-10-Professional-build-19045-64bit',
    },
    auth: {
      'token': c['MUSIC_U'] ?? '',
      'sessionId': c['JSESSIONID-WYYY'] ?? '',
      'vipType': c['vipType'] ?? '',
    },
    startTime: DateTime.now().millisecondsSinceEpoch,
    processId: rng.nextInt(90000) + 10000,
  );
}

/// multipart 封装（对齐 buildMultipart）
({String boundary, String fileName, Uint8List body}) nmNcblBuildMultipart(
  Uint8List payload,
) {
  final rng = math.Random.secure();
  final boundary = _randomHexId();
  final fileName =
      'op_${rng.nextInt(90000) + 10000}_0_${rng.nextInt(0x7fffffff) + 1}';
  const crlf = '\r\n';
  final header = [
    '--$boundary',
    'Content-Disposition: form-data; name="file"; filename="$fileName"',
    'Content-Type: multipart/form-data',
    '',
    '',
  ].join(crlf);
  final footer = '$crlf--$boundary--$crlf';
  return (
    boundary: boundary,
    fileName: fileName,
    body: Uint8List.fromList([
      ...utf8.encode(header),
      ...payload,
      ...utf8.encode(footer),
    ]),
  );
}

String nmNcblBuildCookieStr(NcblContext ctx) => [
      'JSESSIONID-WYYY=${ctx.auth['sessionId']}',
      'MUSIC_U=${ctx.auth['token']}',
      'NMTID=${ctx.device['ti']}',
      'WEVNSM=${ctx.app['nsm']}',
      'WNMCID=${ctx.app['cid']}',
      '__csrf=${ctx.device['csrf']}',
      '__remember_me=true',
      '_iuqxldmzr_=33',
      '_ntes_nnid=${ctx.device['nnid']}',
      '_ntes_nuid=${ctx.device['nuid']}',
      'appver=${ctx.app['version']}.${ctx.app['versionCode']}',
      'channel=${ctx.app['channel']}',
      'clientSign=${ctx.device['sign']}',
      'deviceId=${ctx.device['id']}',
      'mode=${ctx.device['model']}',
      'ntes_kaola_ad=1',
      'os=${ctx.device['systemType']}',
      'osver=${ctx.device['systemVersion']}',
    ].join('; ');

String nmNcblBuildMetaJson(NcblContext ctx) => jsonEncode({
      'JSESSIONID-WYYY': ctx.auth['sessionId'],
      'MUSIC_U': ctx.auth['token'],
      'NMTID': ctx.device['ti'],
      'WEVNSM': ctx.app['nsm'],
      'WNMCID': ctx.app['cid'],
      '__csrf': ctx.device['csrf'],
      '_iuqxldmzr_': '33',
      '_ntes_nnid': ctx.device['nnid'],
      '_ntes_nuid': ctx.device['nuid'],
      'appver': '${ctx.app['version']}.${ctx.app['versionCode']}',
      'channel': ctx.app['channel'],
      'clientSign': ctx.device['sign'],
      'deviceId': ctx.device['id'],
      'mode': ctx.device['model'],
      'ntes_kaola_ad': '1',
      'os': ctx.device['systemType'],
      'osver': ctx.device['systemVersion'],
    });

/// 上传（对齐 doUpload）
Future<NcblUploadResult> nmNcblDoUpload(
  NcblContext ctx,
  String metaJson,
  String body,
  String cookieStr,
) async {
  final payload = nmEncryptNcbl(utf8.encode(metaJson), utf8.encode(body));
  final multipart = nmNcblBuildMultipart(payload);

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client
        .postUrl(Uri.parse(
            '$nmClientLog3Domain/api/clientlog/encrypt/upload?multiupload=true'))
        .timeout(const Duration(seconds: 15));
    req.headers.set('Content-Type', 'multipart/form-data; boundary=${multipart.boundary}');
    req.headers.set('Referer', 'https://music.163.com/di');
    req.headers.set(
        'User-Agent',
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 '
        'NeteaseMusicDesktop/${ctx.app['version']}');
    req.headers.set('Accept-Encoding', 'gzip,deflate');
    req.headers.set('Accept-Language', 'zh-CN,zh;q=0.8');
    req.headers.set('Cookie', cookieStr);
    req.add(multipart.body);
    final res = await req.close().timeout(const Duration(seconds: 15));
    final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));

    Map<String, dynamic> respBody;
    try {
      respBody = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      respBody = {'code': res.statusCode, 'raw': text};
    }
    final files = respBody['data'] is Map
        ? (respBody['data'] as Map)['successfiles']
        : null;
    final success = respBody['code'] == 200 &&
        files is List &&
        files.any((f) => '$f' == multipart.fileName);
    return NcblUploadResult(
      success: success,
      fileName: multipart.fileName,
      payload: payload,
      respBody: respBody,
    );
  } finally {
    client.close(force: true);
  }
}
