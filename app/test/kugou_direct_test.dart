/// 酷狗直连验证：加密/签名单元测试 + 真实链路（搜索 → song_url 音质回退
/// → 可播 URL / 歌词）。
///
/// 真实请求部分验证：
/// - 概念版 lite 平台（appid 3116）注册拿 dfid 后 /v5/url 返回可播 URL
/// - 音质档位缺 hash 时自动降级（不抛错，返回低档 URL）
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archoera_music/services/kugou/kugou_api.dart';
import 'package:archoera_music/services/kugou/kugou_crypto.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ── 加密 / 签名单元测试 ──────────────────────────────────────────

  test('signatureAndroidParams 输出 32 位 hex', () {
    final sig = kgSignature({
      'mid': '12345',
      'appid': 1005,
      'dfid': 'abc',
    });
    expect(sig, matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('signKey 输出 32 位 hex（与 TS 实现同构）', () {
    const hash = 'dd11d3a1e3ce4e38a81aa7f5650c3b87';
    // 与 node `signKey(hash, mid, userid, appid)` 同构：
    // md5(hash + keySalt + appid + mid + userid)
    expect(
      kgSignKey(hash, '12345', 0, 1005, salt: kgKeySalt),
      kgMd5('${hash}57ae12eb6890223e355ccfcb74edf70d1005123450'),
    );
    // lite 盐值：登录态 userid 注入 signKey
    expect(
      kgSignKey(hash, '12345', 7, 3116, salt: kgLiteKeySalt),
      kgMd5('${hash}185672dd44712f60bb1736df5a377e823116123457'),
    );
  });

  test('signatureWeb 输出 32 位 hex（登录接口签名）', () {
    final sig = kgSignatureWeb({
      'plat': 4,
      'appid': 3116,
      'srcappid': 2919,
      'qrcode': 'abc',
    });
    expect(sig, matches(RegExp(r'^[0-9a-f]{32}$')));
    // 与 KuGouMusicApi signatureWebParams 同构：salt+排序k=v+salt
    const str =
        'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt'
        'appid=3116plat=4qrcode=abcsrcappid=2919'
        'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';
    expect(sig, kgMd5(str));
  });

  test('扫码登录：qr/key 真实请求返回 key，qr/check 等待扫码', () async {
    final api = KugouApi();
    final key = await api.qrKey();
    expect(key, isNotEmpty, reason: 'login_qr_key 应返回 key');
    // ignore: avoid_print
    print('[KG] qr key=$key');

    final state = await api.qrCheck(key);
    final status = state['status'];
    expect(status, isNotNull, reason: 'qr/check 应返回 status');
    expect(
      status == 1 || status == 2 || status == 0,
      isTrue,
      reason: '未扫码时应为 等待(1)/已扫(2)/过期(0) 之一，实际=$status',
    );
    // ignore: avoid_print
    print('[KG] qr/check status=$status (等待扫码即可，无需真人扫码)');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('calculateMid 为十进制大整数', () {
    final mid = kgCalcMid(kgRandomString(16));
    expect(mid, isNotEmpty);
    // 十进制数字串（MD5 hex 视作 16 进制大整数 → 十进制）
    expect(BigInt.tryParse(mid), isNotNull);
  });

  test('RSA-PKCS1 加密输出 hex（对齐 rsaEncrypt2）', () {
    final hex = kgRsaPkcs1EncryptHex(
      jsonEncode({'aes': 'a1b2c3', 'uid': 0, 'token': ''}),
    );
    expect(hex, matches(RegExp(r'^[0-9a-f]+$')));
    expect(hex.length, 256); // 1024bit → 128 字节 → 256 hex
  });

  test('AES-CBC 加解密往返（playlistAes 系列）', () {
    final key = kgRandomString(6).toLowerCase();
    final cipher = kgAesEncryptBase64('{"a":1}', key);
    expect(cipher, isNotEmpty);
    final plain = kgAesDecryptString(cipher, key);
    expect(jsonDecode(plain), {'a': 1});
  });

  // ── KRC 解码往返（构造 → 加密 → decodeKrc → 断言） ──────────────

  test('KRC 解码：构造密文往返还原', () {
    const krcKey = <int>[
      0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, //
      0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
    ];
    const raw = '[id:\$Kugou]\n'
        '[ti:小苹果]\n'
        '[ar:筷子兄弟]\n'
        '[0,3000]<0,100,0>小<100,200,0>苹<200,300,0>果\n'
        '[3000,5000]<0,200,0>我<200,300,0>们\n';
    final text = utf8.encode(raw);
    // 真实格式：先 deflate，再对压缩字节 XOR
    final deflated = ZLibCodec().encode(text);
    final xored = Uint8List(deflated.length);
    for (var i = 0; i < deflated.length; i++) {
      xored[i] = deflated[i] ^ krcKey[i % 16];
    }
    final payload = Uint8List(4 + xored.length)..setAll(4, xored);

    final parsed = decodeKrc(base64.encode(payload));
    expect(parsed.lrc, contains('小苹果'));
    expect(parsed.lrc, contains('我们'));
    expect(parsed.krc, contains('<0,100>小'));
    expect(parsed.lrc, isNot(contains('<'))); // 行级 LRC 无字级时间
  });

  // ── 真实链路（搜索 → song_url 音质回退 → 歌词） ──────────────────

  test(
    '直连搜索解析 + song_url（真实请求，音质降级）',
    () async {
      final api = KugouApi();

      // 搜索解析：应返回 kugou 源、带品质 hash 信息
      final result = await api.searchSongs('小苹果', limit: 5);
      expect(result.items, isNotEmpty, reason: 'mobilecdn 应返回歌曲');
      final first = result.items.first;
      expect(first.source, 'kugou');
      expect(first.kugou, isNotNull, reason: '应带品质 hash 信息');
      // ignore: avoid_print
      print('[KG] ${first.title} - ${first.artistNames} '
          '品质=${first.kugou!.available}');

      // 免费歌（小苹果原版 128k，status=1 可播）
      const freeHash = '9ec281b0d7e8d236e435c965b0365b07';
      final info = KugouTrackInfo(
        hash: freeHash,
        hashes: {'128k': freeHash},
        sizes: {'128k': 2992764},
      );

      // lq 档：128k URL
      final urlLq = await api.resolvePlayUrl(info, quality: 'lq');
      expect(urlLq, isNotNull, reason: '128k 应返回可播 URL');
      expect(urlLq, startsWith('http'));

      // hi-res 档：无 hires/flac hash → 自动降级到 128k
      final urlHires = await api.resolvePlayUrl(info, quality: 'hi-res');
      expect(urlHires, isNotNull, reason: 'hi-res 缺档应降级而非失败');
      expect(urlHires, startsWith('http'));
      // ignore: avoid_print
      print('[KG] lq=$urlLq');
      // ignore: avoid_print
      print('[KG] hi-res 降级=$urlHires');
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test('直连歌词（真实请求，KRC 解码）', () async {
    final api = KugouApi();
    final result = await api.searchSongs('小苹果', limit: 1);
    expect(result.items, isNotEmpty);
    final track = result.items.first;
    final hash = track.kugou?.hash ?? '';
    expect(hash, isNotEmpty);

    final lyric = await api.lyric(
      hash: hash,
      name: track.title,
      durationSeconds: track.duration ~/ 1000,
    );
    expect(lyric, isNotNull, reason: '应能取到歌词');
    expect(lyric!.lrc, isNotEmpty);
    // ignore: avoid_print
    print('[KG] 歌词首行: ${lyric.lrc.split('\n').first}');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('登录态注入：session 保存 + 带 token 请求链路正常', () async {
    final api = KugouApi();
    api.saveSession('fake-token-for-sign', '7', nickname: '测试');
    expect(api.isLoggedIn, isTrue);
    expect(api.session!.userid, '7');
    // 带无效 token 请求：服务器可能拒绝（返回 null）或仍放行，
    // 关键是不抛异常、链路可用（有效 token 需真人扫码后才有）。
    const freeHash = '9ec281b0d7e8d236e435c965b0365b07';
    final info = KugouTrackInfo(
      hash: freeHash,
      hashes: {'128k': freeHash},
      sizes: {'128k': 2992764},
    );
    final url = await api.resolvePlayUrl(info, quality: 'lq');
    // ignore: avoid_print
    print('[KG] 登录态 resolvePlayUrl → '
        '${url ?? '(null，无效 token 被拒属正常)'}');
  }, timeout: const Timeout(Duration(seconds: 30)));
}
