/// QM（QM）直连验证：真实请求云端。
///
/// 覆盖：
/// - 搜索 → 归一 Track（含 mid/mediaMid/cover）
/// - song_url：访客可对免费曲目取到可播 URL；VIP 曲目按接口语义抛 403
/// - 扫码登录：qq 出码真实请求（不扫码，仅验证拿到 key + 图）
library;

import 'package:archoera_music/apis/qqmusic/api.dart';
import 'package:archoera_music/apis/qqmusic/core/qrc.dart';
import 'package:archoera_music/services/netease/netease_api.dart';
import 'package:archoera_music/services/netease/track.dart';
import 'package:archoera_music/services/qqmusic/qqmusic_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ── 单元：QRC 解密（非真实请求） ─────────────────────────────────

  test('qmDecryptQrc：无数据抛错', () {
    expect(() => qmDecryptQrc(''), throwsA(anything));
  });

  // ── 真实链路（搜索 → song_url 直链） ─────────────────────────────
  final api = QqMusicApi();

  test('直连搜索解析（真实请求）', () async {
    final result = await api.searchSongs('命运交响曲 贝多芬', page: 1, limit: 3);
    expect(result.items, isNotEmpty);
    final first = result.items.first;
    expect(first.source, 'qqmusic');
    expect(first.qqmusic, isNotNull);
    expect(first.qqmusic!.mid, isNotEmpty);
    expect(first.qqmusic!.mediaMid, isNotEmpty);
    expect(first.title, isNotEmpty);
    expect(first.duration, greaterThan(0));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('song_url：免费曲目访客可播（真实请求）', () async {
    // 古典公版曲目通常无需会员即可拿 M500/M800 直链
    final result = await api.searchSongs('命运交响曲 贝多芬', page: 1, limit: 5);
    String? url;
    Object? lastErr;
    for (final t in result.items.take(3)) {
      try {
        url = await api.resolvePlayUrl(t, quality: 'hq');
        if (url != null && url.isNotEmpty) break;
      } catch (e) {
        lastErr = e;
      }
    }
    expect(url, isNotNull, reason: '免费曲目应能取到直链: $lastErr');
    expect(url, startsWith('http'));
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('song_url：VIP 曲目按接口语义拒绝（不绕过）', () async {
    final result = await api.searchSongs('晴天 周杰伦', page: 1, limit: 1);
    expect(result.items, isNotEmpty);
    expect(
      () => api.resolvePlayUrl(result.items.first, quality: 'hq'),
      throwsA(isA<QqApiException>()),
    );
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('登录出码：qq 扫码拿到 key + base64 图（真实请求，不扫码）', () async {
    final qr = await api.qrKey('qq');
    expect(qr['key'], isNotEmpty);
    expect(qr['content'], startsWith('data:image/'));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('歌词 lyric（真实请求，QRC/LRC 解密链路）', () async {
    final result = await api.searchSongs('晴天 周杰伦', page: 1, limit: 1);
    expect(result.items, isNotEmpty);
    final id = result.items.first.id;
    final body = await qmCall('lyric', {'id': id});
    expect(body, isA<Map>());
    // 歌词内容非空或明确失败都允许；但必须有 code 字段（不抛网络错）
    expect((body as Map).containsKey('code'), isTrue);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('歌单详情 song_list（真实请求）', () async {
    final tracks = await api.playlistTracks('2340100311');
    // QM官方巅峰榜歌单；只验证链路不崩，曲目可空
    expect(tracks, isA<List<Track>>());
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('搜索返回 SearchResult 语义（真实请求）', () async {
    final r = await api.searchAlbums('周杰伦', page: 1, limit: 5);
    expect(r, isA<SearchResult<CoverItem>>());
  }, timeout: const Timeout(Duration(seconds: 30)));
}
