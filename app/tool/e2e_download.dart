/// 真实下载联调工具（纯 Dart，无 flutter 依赖）。
///
/// 验证 Rust 下载内核在真实网络环境下的端到端链路：
///   enqueue → Rust 内部 URL 解析（Kugou register_dev+v5/url / Netease weapi）
///   → 流式分块下载 → done 事件 → 文件落盘（fsync + 原子 rename）。
///
/// 用法（在 app/ 目录下）：
///   # 搜索并下载 Kugou 第一首
///   dart run tool/e2e_download.dart --source kugou --keyword 晴天
///   # 直接指定 Kugou hash（跳过搜索）
///   dart run tool/e2e_download.dart --source kugou --hash <40位hex> --title 晴天 --artist 周杰伦
///   # 搜索并下载 Netease 第一首（需选免费曲，VIP 会走降级链失败）
///   dart run tool/e2e_download.dart --source netease --keyword 云烟成雨
///   # 直接指定 Netease song id
///   dart run tool/e2e_download.dart --source netease --song-id 462793690
///
/// 可选参数：
///   --quality  lq|sq|hq|lossless|hi-res（默认 hq = 320k，Rust 内部自动降级）
///   --root     下载根目录（默认 /tmp/archoera_e2e_download）
///   --timeout  总超时秒数（默认 180）
///   --keep     保留下载目录（默认退出前删除）
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:archoera_music/apis/kugou/api.dart';
import 'package:archoera_music/apis/netease/api.dart';
import 'package:archoera_music/services/downloader/downloader_ffi.dart';

const _defaultRoot = '/tmp/archoera_e2e_download';

// ─────────────────────────────────────────────────────────────
// 参数解析
// ─────────────────────────────────────────────────────────────

class _Args {
  String source = 'kugou';
  String? keyword;
  String? hash;
  String? songId;
  String title = '';
  String artist = '';
  String album = '';
  String quality = 'hq';
  String root = _defaultRoot;
  int timeoutSec = 180;
  bool keep = false;
}

_Args _parseArgs(List<String> args) {
  final a = _Args();
  for (var i = 0; i < args.length; i++) {
    String next(String name) {
      if (i + 1 >= args.length) throw StateError('缺少 $name 的值');
      return args[++i];
    }

    switch (args[i]) {
      case '--source':
        a.source = next('--source');
        break;
      case '--keyword':
        a.keyword = next('--keyword');
        break;
      case '--hash':
        a.hash = next('--hash');
        break;
      case '--song-id':
        a.songId = next('--song-id');
        break;
      case '--title':
        a.title = next('--title');
        break;
      case '--artist':
        a.artist = next('--artist');
        break;
      case '--album':
        a.album = next('--album');
        break;
      case '--quality':
        a.quality = next('--quality');
        break;
      case '--root':
        a.root = next('--root');
        break;
      case '--timeout':
        a.timeoutSec = int.parse(next('--timeout'));
        break;
      case '--keep':
        a.keep = true;
        break;
      default:
        throw StateError('未知参数: ${args[i]}');
    }
  }
  if (a.source != 'kugou' && a.source != 'netease') {
    throw StateError('--source 只支持 kugou / netease');
  }
  if (!{'lq', 'sq', 'hq', 'lossless', 'hi-res'}.contains(a.quality)) {
    throw StateError('--quality 非法: ${a.quality}');
  }
  return a;
}

// ─────────────────────────────────────────────────────────────
// 搜索（拿真实数据喂给 Rust 下载器）
// ─────────────────────────────────────────────────────────────

/// 返回 (song, request)：request 为可直接 enqueue 的 JSON（Rust 全权解析 URL）
Future<(Map<String, dynamic>, Map<String, dynamic>)> _kugouSearch(
    String keyword) async {
  final result = await kgCall('search', {
    'keywords': keyword,
    'limit': 8,
  });
  final songs = (result as Map)['songs'] as List;
  if (songs.isEmpty) throw StateError('Kugou 搜索无结果: $keyword');
  final s = songs.first as Map<String, dynamic>;
  final request = {
    'trackId': 'e2e-${s['id']}',
    'source': 'kugou',
    'platformId': '${s['id']}',
    'quality': 'hq',
    'title': '${s['name']}',
    'artist': '${s['artist']}',
    'album': '${s['album']}',
    'extra': {
      'hashes': s['hashes'] ?? const <String, String>{},
      'sizes': s['sizes'] ?? const <String, int>{},
    },
  };
  return (s, request);
}

Future<(Map<String, dynamic>, Map<String, dynamic>)> _neteaseSearch(
    String keyword) async {
  final res = await nmCallNetease('search', {
    'keywords': keyword,
    'limit': 8,
    'type': 1,
  });
  final result = res.body['result'];
  final songs = result is Map ? (result['songs'] as List? ?? const []) : const [];
  if (songs.isEmpty) throw StateError('Netease 搜索无结果: $keyword');
  final s = songs.first as Map<String, dynamic>;
  final artists = (s['ar'] as List? ?? const [])
      .map((a) => a is Map ? '${a['name']}' : '')
      .where((x) => x.isNotEmpty)
      .join(' / ');
  final request = {
    'trackId': 'e2e-${s['id']}',
    'source': 'netease',
    'platformId': '${s['id']}',
    'quality': 'hq',
    'title': '${s['name']}',
    'artist': artists,
  };
  return (s, request);
}

// ─────────────────────────────────────────────────────────────
// 下载执行
// ─────────────────────────────────────────────────────────────

Future<void> _runDownload(
  _Args a,
  Map<String, dynamic> request, {
  Map<String, String>? kugouSession,
  Map<String, String>? neteaseCookie,
}) async {
  final lib = DownloaderLibrary.load();
  final events = <Map<String, dynamic>>[];
  final done = Completer<String>(); // 'done' / 'error' / 'timeout'
  final soPath = DownloaderLibrary.resolveSoPath();
  stderr.writeln('[*] .so = $soPath');

  // 戒律 13.1：唯一事件通道 = NativeCallable.listener 回调（无轮询）
  final callable =
      NativeCallable<Void Function(Pointer<Utf8>)>.listener((Pointer<Utf8> ptr) {
    if (ptr == nullptr) return;
    final str = ptr.toDartString();
    try {
      lib.free(ptr.cast<Void>()); // 戒律 13.3：必须 free
    } catch (_) {}
    try {
      final evt = jsonDecode(str) as Map<String, dynamic>;
      events.add(evt);
      final type = evt['type'];
      if (type == 'done' || type == 'error' || type == 'already') {
        if (!done.isCompleted) done.complete('$type');
      }
    } catch (e) {
      stderr.writeln('[!] 事件解析失败: $e (raw: $str)');
    }
  });
  final rootDir = a.root;
  final code = lib.init(
    rootDir: rootDir,
    subdirStrategy: 1,
    maxConcurrent: 2,
    eventCb: callable.nativeFunction.cast<Void>(),
    freeFn: null,
  );
  if (code != 0) throw StateError('init 失败 code=$code');
  stderr.writeln('[*] init OK: root=$rootDir');

  // 登录态注入（戒律 13.2：Rust 内部以注入的 session/cookie 为准）
  if (kugouSession != null && kugouSession.isNotEmpty) {
    final uid = kugouSession['userid'] ?? '';
    final tok = kugouSession['token'] ?? '';
    if (uid.isNotEmpty && tok.isNotEmpty) {
      final c = lib.setKugouSession(uid, tok);
      stderr.writeln('[*] setKugouSession uid=$uid code=$c');
    }
  }
  if (neteaseCookie != null && neteaseCookie.isNotEmpty) {
    final c = lib.setNeteaseCookie(
      neteaseCookie.entries.map((e) => '${e.key}=${e.value}').join('; '),
    );
    stderr.writeln('[*] setNeteaseCookie keys=${neteaseCookie.keys.toList()} code=$c');
  }

  final (enqCode, taskId) = lib.enqueue(request);
  if (enqCode != 0) throw StateError('enqueue 失败 code=$enqCode');
  stderr.writeln('[*] enqueue OK: taskId=$taskId');

  final outcome = await done.future.timeout(
    Duration(seconds: a.timeoutSec),
    onTimeout: () => 'timeout',
  );

  // 汇总
  stderr.writeln('\n=== 事件序列（共 ${events.length} 条）===');
  for (final e in events) {
    stderr.writeln('  ${jsonEncode(e)}');
  }
  stderr.writeln('\n=== 结果: $outcome ===');

  final finalEvent = events.isNotEmpty ? events.last : null;
  if (outcome == 'done' && finalEvent != null) {
    final path = finalEvent['filePath'] as String;
    final f = File(path);
    if (!f.existsSync()) {
      stderr.writeln('[FAIL] done 事件指向的文件不存在: $path');
      exitCode = 1;
      return;
    }
    final len = f.lengthSync();
    stderr.writeln('[OK] 文件存在: $path');
    stderr.writeln('[OK] 大小: $len bytes（事件声称 ${finalEvent['fileSize']}）');
    // magic 头：ID3/0xFF 0xFB → mp3；fLaC → flac
    final raf = f.openSync(mode: FileMode.read);
    final head = raf.readSync(8);
    raf.closeSync();
    final hex = head.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    final kind = (head.length >= 4 && String.fromCharCodes(head, 0, 4) == 'fLaC')
        ? 'FLAC'
        : (head.length >= 3 && String.fromCharCodes(head, 0, 3) == 'ID3')
            ? 'MP3(ID3)'
            : (head.length >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0)
                ? 'MP3(frame)'
                : '未知';
    stderr.writeln('[OK] 文件头 8 字节: $hex  → $kind');
    if (len <= 0) {
      stderr.writeln('[FAIL] 文件大小为 0');
      exitCode = 1;
      return;
    }
    stderr.writeln('[PASS] 真实下载链路验证通过');
  } else {
    stderr.writeln('[FAIL] 未完成，outcome=$outcome');
    if (finalEvent != null && finalEvent['error'] != null) {
      stderr.writeln('      error: ${finalEvent['error']}');
    }
    exitCode = 1;
  }

  lib.destroy();
  try {
    callable.close();
  } catch (_) {}
}

/// 从数据目录 `netease_session.json` 读取 {kugou, netease} 会话（与 App 同源）
Map<String, Map<String, String>?> _loadStoredSessions() {
  final home = Platform.environment['HOME'] ?? '.';
  final file = File(
    '${Platform.isLinux ? '$home/.local/share' : '$home/AppData/Local'}/ArchoeraMusic/netease_session.json',
  );
  if (!file.existsSync()) return const {};
  try {
    final all = jsonDecode(file.readAsStringSync());
    if (all is! Map<String, dynamic>) return const {};
    Map<String, String>? asMap(String key) {
      final raw = all[key];
      if (raw is! Map) return null;
      return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    }

    return {
      'kugou': asMap('kugou'),
      'netease': asMap('netease'),
    };
  } catch (_) {
    return const {};
  }
}

// ─────────────────────────────────────────────────────────────
// main
// ─────────────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  final a = _parseArgs(args);
  stderr.writeln('[*] source=${a.source} quality=${a.quality} keyword=${a.keyword ?? '-'} '
      'hash=${a.hash ?? '-'} songId=${a.songId ?? '-'}');

  Map<String, dynamic> request;
  Map<String, dynamic> song;
  if (a.source == 'kugou') {
    if (a.hash != null) {
      request = {
        'trackId': 'e2e-manual',
        'source': 'kugou',
        'platformId': a.songId ?? a.hash!,
        'quality': a.quality,
        'title': a.title.isEmpty ? 'manual' : a.title,
        'artist': a.artist,
        'album': a.album,
        'extra': {'hashes': const <String, String>{}, 'sizes': const <String, int>{}},
      };
      // 仅指定了 hash 时按档位填入（从 128k 到 flac24bit 全部指向同一 hash，
      // 由 Rust 降级链决定实际命中；也可用 --hash + 手动构造）
      final h = a.hash!;
      (request['extra'] as Map)['hashes'] = {
        '128k': h,
        '320k': h,
        'flac': h,
        'flac24bit': h,
      };
    } else if (a.keyword != null) {
      (song, request) = await _kugouSearch(a.keyword!);
      request['quality'] = a.quality;
      stderr.writeln(
          '[*] 搜索命中: ${song['name']} - ${song['artist']}  id=${song['id']}  hash=${song['hash']}');
      final hs = (song['hashes'] as Map?) ?? const <String, String>{};
      stderr.writeln('[*] 可用品质: ${hs.keys.toList()}');
    } else {
      throw StateError('kugou 需要 --keyword 或 --hash');
    }
  } else {
    if (a.songId != null) {
      request = {
        'trackId': 'e2e-manual',
        'source': 'netease',
        'platformId': a.songId!,
        'quality': a.quality,
        'title': a.title.isEmpty ? 'manual' : a.title,
        'artist': a.artist,
      };
    } else if (a.keyword != null) {
      (song, request) = await _neteaseSearch(a.keyword!);
      request['quality'] = a.quality;
      final s = song;
      final artists = (s['ar'] as List? ?? const [])
          .map((x) => x is Map ? '${x['name']}' : '')
          .where((x) => x.isNotEmpty)
          .join(' / ');
      stderr.writeln('[*] 搜索命中: ${s['name']} - $artists  id=${s['id']}');
    } else {
      throw StateError('netease 需要 --keyword 或 --song-id');
    }
  }

  stderr.writeln('[*] request JSON: ${jsonEncode(request)}');

  if (Directory(a.root).existsSync() && !a.keep) {
    Directory(a.root).deleteSync(recursive: true);
  }
  Directory(a.root).createSync(recursive: true);

  // 从数据目录读取已登录的会话（netease_session.json，kugou 同文件）
  final sessions = _loadStoredSessions();
  final kugouSession = sessions['kugou'];
  final neteaseCookie = sessions['netease'];

  try {
    await _runDownload(
      a,
      request,
      kugouSession: kugouSession,
      neteaseCookie: neteaseCookie,
    );
  } finally {
    if (!a.keep) {
      try {
        Directory(a.root).deleteSync(recursive: true);
        stderr.writeln('[*] 已清理 $a.root（--keep 可保留）');
      } catch (_) {}
    }
  }
}
