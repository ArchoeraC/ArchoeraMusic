/// 网易云直连验证：真实请求云端，验证 weapi/eapi 加密 + 请求层 + 解析链路。
///
/// 若加密/请求层与 TS 实现不一致，服务端会返回非 200（参数错误），
/// 因此「cloudsearch 返回歌曲 + song_url 返回可播 URL」即为正确性证明。
///
/// 加密原语与请求层来自 apis 包（app/lib/core/apis/netease/，纯 Dart 直连）。
library;

import 'package:archoera_music/apis/netease/core/crypto.dart';
import 'package:archoera_music/services/netease/apis_netease_caller.dart';
import 'package:archoera_music/services/netease/netease_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('weapi 输出结构', () {
    final enc = nmWeapi({'s': 'test', 'type': 1, 'limit': 1, 'offset': 0, 'total': true});
    expect(enc.params, isNotEmpty);
    expect(enc.params, contains(RegExp(r'^[A-Za-z0-9+/=]+$'))); // base64
    expect(enc.encSecKey, matches(RegExp(r'^[0-9a-f]{256}$'))); // 256 位 hex
  });

  test('eapi 输出为 32+ 大写 hex', () {
    final out = nmEapi('/api/cloudsearch/pc', {'s': 'test', 'header': {}});
    expect(out, matches(RegExp(r'^[0-9A-F]+$')));
    expect(out.length % 32, 0);
  });

  test('RSA 裸加密输出定长 256 hex', () {
    final hex = nmRsaEncrypt('secret-key-reversed');
    expect(hex, matches(RegExp(r'^[0-9a-f]{256}$')));
  });

  test(
    '直连 cloudsearch + song_url（真实请求）',
    () async {
      final api = NeteaseApi(ApisNeteaseCaller());

      // cloudsearch：周杰伦 前 3 首
      final result = await api.searchSongs('周杰伦', limit: 3);
      expect(result.items, isNotEmpty, reason: 'cloudsearch 应返回歌曲');
      expect(result.total, greaterThanOrEqualTo(result.items.length));

      // song_url：第一首歌取可播 URL
      final url = await api.resolvePlayUrl(result.items.first.id);
      expect(url, isNotNull, reason: 'song_url 应返回可播 URL');
      expect(url!.startsWith('http'), isTrue);
      // ignore: avoid_print
      print('URL[${result.items.first.title}] -> $url');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
