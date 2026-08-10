// 临时冒烟测试：验证 apis 纯 Dart 直连三平台核心链路。
// 用法：dart run tool/apis_smoke.dart
// ignore_for_file: avoid_print
import 'package:archoera_music/apis/kugou/api.dart';
import 'package:archoera_music/apis/lyric/kugou.dart';
import 'package:archoera_music/apis/lyric/netease.dart';
import 'package:archoera_music/apis/lyric/qqmusic.dart';
import 'package:archoera_music/apis/netease/api.dart';
import 'package:archoera_music/apis/qqmusic/api.dart';
import 'package:archoera_music/services/netease/track.dart';

Future<void> main() async {
  var pass = 0;
  var fail = 0;

  void ok(String label, Object? v) {
    pass++;
    print('PASS [$label] ${v ?? 'null'}');
  }

  void bad(String label, String reason) {
    fail++;
    print('FAIL [$label] $reason');
  }

  // ── 1. netease 搜索 ──────────────────────────────
  try {
    final r = await nmCallNetease('cloudsearch', {'keywords': '晴天 周杰伦', 'limit': 1});
    final songs = (r.body['result'] as Map?)?['songs'] as List? ?? const [];
    if (r.status == 200 && r.body['code'] == 200 && songs.isNotEmpty) {
      final s = (songs.first as Map).cast<String, dynamic>();
      ok('netease search', '${s['name']} / ${s['ar'] ?? ''} / id=${s['id']}');
    } else {
      bad('netease search', 'status=${r.status} code=${r.body['code']}');
    }
  } catch (e) {
    bad('netease search', '$e');
  }

  // ── 2. netease 取播放 URL ─────────────────────────
  try {
    final r = await nmCallNetease('song_url', {'id': 347230, 'level': 'standard'});
    final data = r.body['data'] as List? ?? const [];
    if (r.body['code'] == 200 && data.isNotEmpty) {
      final url = (data.first as Map)['url']?.toString() ?? '';
      if (url.isNotEmpty) {
        ok('netease song_url', '${url.substring(0, 40)}...');
      } else {
        bad('netease song_url', 'empty url (可能需登录)');
      }
    } else {
      bad('netease song_url', 'code=${r.body['code']}');
    }
  } catch (e) {
    bad('netease song_url', '$e');
  }

  // ── 3. qqmusic 搜索 ───────────────────────────────
  try {
    final body = await qmCall('search', {'keywords': '晴天', 'limit': 1});
    final m = body is Map ? body : const <String, dynamic>{};
    final songs = m['songs'] as List? ?? const [];
    if (m['code'] == 200 && songs.isNotEmpty) {
      final s = (songs.first as Map).cast<String, dynamic>();
      ok('qqmusic search', '${s['name']} / ${s['artist']} / id=${s['id']}');
    } else {
      bad('qqmusic search', 'code=${m['code']} songs=${songs.length}');
    }
  } catch (e) {
    bad('qqmusic search', '$e');
  }

  // ── 4. kugou 搜索 ─────────────────────────────────
  try {
    final body = await kgCall('search', {'keywords': '晴天 周杰伦', 'limit': 1});
    final m = body is Map ? body : const <String, dynamic>{};
    final songs = m['songs'] as List? ?? const [];
    if (m['code'] == 200 && songs.isNotEmpty) {
      final s = (songs.first as Map).cast<String, dynamic>();
      ok('kugou search', '${s['name']} / ${s['artist']} / hash=${s['hash']}');
    } else {
      bad('kugou search', 'code=${m['code']} songs=${songs.length}');
    }
  } catch (e) {
    bad('kugou search', '$e');
  }

  // ── 5. lyric 层（netease byId）───────────────────
  try {
    final lr = await nmGetLyricByPlatformId('347230');
    if (lr != null) {
      ok('netease lyric', '${lr.format} ${lr.content.length}chars${lr.translation != null ? ' +trans' : ''}');
    } else {
      bad('netease lyric', 'null');
    }
  } catch (e) {
    bad('netease lyric', '$e');
  }

  // ── 6. lyric 层（qqmusic byQuery）────────────────
  final track = Track(
    id: '',
    title: '晴天',
    artists: const [TrackArtist(name: '周杰伦')],
    duration: 269000,
  );
  try {
    final lr = await qmGetLyricByQuery(track);
    if (lr != null) {
      ok('qqmusic lyric', '${lr.format} ${lr.content.length}chars');
    } else {
      bad('qqmusic lyric', 'null');
    }
  } catch (e) {
    bad('qqmusic lyric', '$e');
  }

  // ── 7. lyric 层（kugou byQuery）──────────────────
  try {
    final lr = await kgGetLyricByQuery(track);
    if (lr != null) {
      ok('kugou lyric', '${lr.format} ${lr.content.length}chars${lr.translation != null ? ' +trans' : ''}');
    } else {
      bad('kugou lyric', 'null');
    }
  } catch (e) {
    bad('kugou lyric', '$e');
  }

  print('\n== smoke: $pass pass, $fail fail ==');
}
