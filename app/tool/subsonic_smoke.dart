// 冒烟测试：Subsonic 服务端（Go FFI）+ 客户端（纯 Dart）闭环。
// 链路：
//   1. 构造临时曲库（tracks + subsonic 6 表）+ 测试 WAV
//   2. SubsonicController create → poll started（绑定 0.0.0.0 + 端口 0 →
//      系统分配端口，实际地址经 started 事件回传；密钥自动生成到 dataDir/secret.key）
//   3. SubsonicLocalServer.register 注册协商信息；客户端开启 isArchoeraServer
//      仅填主机，端口自动协商（仅换端口、保留主机，覆盖 IPv6/域名）
//   4. SubsonicAdmin 创建用户（encrypt 密码）
//   5. SubsonicClient 闭环：ping / listAlbums / getAlbumSongs /
//      stream 转码（dlopen Rust）/ getLyrics（歌词桥 lyric-request → respondLyric）
//   6. destroy
// 用法：dart run tool/subsonic_smoke.dart
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archoera_music/services/streaming/streaming_types.dart';
import 'package:archoera_music/services/subsonic/subsonic_admin.dart';
import 'package:archoera_music/services/subsonic/subsonic_bindings.dart';
import 'package:archoera_music/services/subsonic/subsonic_client.dart';
import 'package:archoera_music/services/subsonic/subsonic_controller.dart';
import 'package:archoera_music/services/subsonic/subsonic_local.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

void main() async {
  // 0) 库定位
  final so = SubsonicBindings.resolveSoPath();
  if (so == null) {
    print('FAIL: 未定位到 libarchoera_subsonic');
    exit(1);
  }
  print('OK: 库路径 $so');

  final tmp = Directory.systemTemp.createTempSync('subsonic_smoke');
  final dataDir = '${tmp.path}/data';
  final musicDir = '${tmp.path}/music';
  Directory(dataDir).createSync();
  Directory(musicDir).createSync();
  final dbPath = '$dataDir/database/library.db';
  Directory('$dataDir/database').createSync(recursive: true);
  final userDbPath = subsonicUserDbPath(dbPath); // $dataDir/database/user.db

  // 1) 构造曲库（tracks + 旧版 subsonic_* 6 表于 library.db，模拟升级前安装）
  final wavPath = '$musicDir/tone.wav';
  _writeWav(wavPath, 44100, 2);
  _createDb(dbPath, wavPath);
  print('OK: 曲库 + 测试音频就绪 ($wavPath)');

  // 2) 创建服务端（异步启动；addr 与 secretKey 均不指定：
  //    端口 0 由系统分配 → 实际地址经 started 事件协商回传；
  //    密钥由服务端自动生成并持久化到 dataDir/secret.key）
  final controller = SubsonicController(SubsonicConfig(
    dbPath: dbPath,
    musicDir: musicDir,
    dataDir: dataDir,
    transcoder: '${Directory.current.path}/core/subsonic/build/libarchoera_transcoder.so',
  ));
  print('OK: create');

  // 3) 等待 started 事件
  SubsonicStarted? started;
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    final ev = controller.pollEvent();
    if (ev is SubsonicStarted) {
      started = ev;
      break;
    }
    if (ev is SubsonicServerError) {
      print('FAIL: 启动错误: ${ev.message}');
      exit(1);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (started == null) {
    print('FAIL: 10s 内未收到 started 事件');
    exit(1);
  }
  print('OK: started addr=${started.addr} db=${started.dbPath}');

  // 3b) 协商验证：服务端已自动生成并持久化凭据密钥（未注入 secretKey）
  final keyFile = File('$dataDir/secret.key');
  if (!keyFile.existsSync()) {
    print('FAIL: 服务端未自动生成 dataDir/secret.key');
    exit(1);
  }
  print('OK: 服务端自动生成凭据密钥 (${keyFile.path})');

  // 3c) 协商验证：注册本机内置服务端（started 地址）。开启
  //     isArchoeraServer 后仅填主机，端口自动协商（仅换端口、保留主机，
  //     覆盖 localhost / 局域网 IPv4 / IPv6 / 域名）；外部服务端手动端口。
  SubsonicLocalServer.register(started.addr);
  final expectedPort = Uri.parse('http://${started.addr}').port;
  for (final host in ['127.0.0.1', '192.168.1.5', '::1', '[fe80::1]', 'nas.example.com']) {
    final resolved = resolvedServerBaseUrl(StreamingServerConfig.ownSubsonic(
        id: 'smoke', host: host, username: 'testuser', password: 'pass1234'));
    final expectedHost = host.startsWith('[') ? host : (host.contains(':') ? '[$host]' : host);
    final expected = 'http://$expectedHost:$expectedPort';
    if (resolved != expected) {
      print('FAIL: 协商 URL 异常: $host → $resolved, 期望 $expected');
      exit(1);
    }
  }
  final external = resolvedServerBaseUrl(StreamingServerConfig(
    id: 'ext',
    name: 'ext',
    type: StreamingServerType.navidrome,
    host: '192.168.1.9',
    port: 4533,
    username: 'u',
    password: 'p',
  ));
  if (external != 'http://192.168.1.9:4533') {
    print('FAIL: 外部服务端手动端口异常: $external');
    exit(1);
  }
  print('OK: 端口协商（端口 $expectedPort，保留主机；外部服务端手动端口）');

  // 3d) 自动迁移验证：服务端启动时应把 library.db 遗留的 subsonic_* 数据
  //     复制到 user.db 并删除媒体库旧表（幂等）
  _checkMigration(dbPath, userDbPath);

  // 4) Admin：创建用户（密码走 FFI encrypt 落盘）——打开独立用户库 user.db
  final admin = SubsonicAdmin.open(controller, userDbPath);
  try {
    admin.createUser(username: 'testuser', password: 'pass1234', isAdmin: true);
    final u = admin.getUserByUsername('testuser');
    if (u == null || u.password != 'pass1234') {
      print('FAIL: 用户密码加解密闭环失败: $u');
      exit(1);
    }
    print('OK: 用户创建 + 密码加解密闭环 (${u.id})');
  } finally {
    admin.close();
  }

  // 5) 客户端闭环：连接 ArchoeraMusic 内置服务端（isArchoeraServer），
  //    仅填主机 127.0.0.1，端口运行时自动协商为 started.addr 的真实端口
  final client = SubsonicClient(StreamingServerConfig.ownSubsonic(
    id: 'smoke',
    host: '127.0.0.1',
    username: 'testuser',
    password: 'pass1234',
  ));

  final ping = await client.ping();
  if (!ping.ok) {
    print('FAIL: ping: ${ping.error}');
    exit(1);
  }
  print('OK: ping version=${ping.version}');

  final albums = await client.listAlbums();
  if (albums.isEmpty || albums.first.name != 'Smoke Album') {
    print('FAIL: listAlbums 期望 Smoke Album, 实际 ${albums.map((a) => a.name).toList()}');
    exit(1);
  }
  print('OK: listAlbums ${albums.length} (${albums.first.name})');

  final songs = await client.getAlbumSongs(albums.first.id);
  if (songs.isEmpty) {
    print('FAIL: getAlbumSongs 空');
    exit(1);
  }
  print('OK: getAlbumSongs ${songs.length} (${songs.first.title} / '
      '${songs.first.artists.map((a) => a.name).join(',')})');

  // 6a) format=raw（客户端流 URL）：返回原文件（WAV RIFF）
  final streamUrl = client.getStreamUrl(songs.first.id.split(':').last);
  final http = HttpClient();
  final req = await http.getUrl(Uri.parse(streamUrl));
  final res = await req.close();
  final body = await res.fold<BytesBuilder>(BytesBuilder(), (b, c) => b..add(c));
  final bytes = body.takeBytes();
  if (res.statusCode != 200 || bytes.length < 1000 ||
      !(bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46)) {
    print('FAIL: stream raw 应返回原 WAV (RIFF), got status=${res.statusCode} '
        'len=${bytes.length} head=${bytes.take(4).map((b) => b.toRadixString(16)).join(' ')}');
    exit(1);
  }
  print('OK: stream raw 直放原文件 ${bytes.length} bytes (RIFF)');

  // 6b) 转码：format=mp3 → dlopen Rust 转码器 → MP3 帧头 (fffb)
  final http2 = HttpClient();
  final streamBase = resolvedServerBaseUrl(client.config);
  final req2 = await http2.getUrl(Uri.parse(client.attachAuthToUrl(
      '$streamBase/rest/stream?id=${songs.first.id.split(':').last}&format=mp3&maxBitRate=96')));
  final res2 = await req2.close();
  final body2 = await res2.fold<BytesBuilder>(BytesBuilder(), (b, c) => b..add(c));
  http2.close();
  final bytes2 = body2.takeBytes();
  if (res2.statusCode != 200 || bytes2.length < 1000 ||
      bytes2[0] != 0xff || (bytes2[1] & 0xe0) != 0xe0) {
    print('FAIL: stream 转码异常 status=${res2.statusCode} len=${bytes2.length} '
        'head=${bytes2.take(4).map((b) => b.toRadixString(16)).join(' ')}');
    print('BODY: ${utf8.decode(bytes2.take(300).toList(), allowMalformed: true)}');
    exit(1);
  }
  print('OK: stream 转码 MP3 ${bytes2.length} bytes (fffb)');

  // 7) 歌词桥：getLyrics → lyric-request 事件 → respondLyric
  //    （Dart HTTP 请求挂起时事件循环仍可 poll controller 事件）
  String? lyricResp;
  var lyricDone = false;
  final lyricFuture = client
      .getLyrics(songs.first.id, artist: 'Smoke Artist', title: songs.first.title)
      .then((v) {
        lyricResp = v;
        lyricDone = true;
      });
  final lyricDeadline = DateTime.now().add(const Duration(seconds: 10));
  while (!lyricDone && DateTime.now().isBefore(lyricDeadline)) {
    final ev = controller.pollEvent();
    if (ev is SubsonicLyricRequest) {
      print('OK: lyric-request id=${ev.requestId} song=${ev.songId}');
      controller.respondLyric(ev.requestId, jsonEncode({'main': '[00:00.00]Smoke lyric'}));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  await lyricFuture;
  if (lyricResp == null || !lyricResp!.contains('Smoke lyric')) {
    print('FAIL: 歌词桥返回异常: $lyricResp');
    exit(1);
  }
  print('OK: 歌词桥闭环: $lyricResp');

  // 8) destroy
  controller.dispose();
  print('SMOKE ALL PASS');
}

/// 迁移前的旧版密码密文（固定桩，仅验证原样搬运，不参与登录）。
const _legacyCipher = 'enc:v1:00000000000000000000000000000000:'
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// 构造曲库：library.db（tracks + 旧版 subsonic_* 6 表，模拟升级前安装）。
///
/// 旧版用户数据（legacyuser 用户 / 收藏 / 播放列表 / 分享各一）将由服务端
/// 启动时的 MigrateUserDB 自动迁往 user.db 并删除媒体库旧表。
void _createDb(String dbPath, String wavPath) {
  final db = sql.sqlite3.open(dbPath);
  db.execute('''
    CREATE TABLE tracks (
      id TEXT PRIMARY KEY,
      path TEXT NOT NULL UNIQUE,
      title TEXT NOT NULL,
      track INTEGER,
      artists TEXT NOT NULL DEFAULT '[]',
      album TEXT,
      duration INTEGER NOT NULL,
      cover TEXT,
      codec TEXT,
      sample_rate INTEGER,
      bit_rate INTEGER,
      channels INTEGER,
      bits_per_sample INTEGER,
      file_size INTEGER NOT NULL,
      file_mtime INTEGER,
      file_ctime INTEGER,
      scanned_at INTEGER NOT NULL,
      lyrics TEXT,
      genre TEXT
    );
    INSERT INTO tracks (id, path, title, track, artists, album, duration, codec,
                        sample_rate, bit_rate, channels, bits_per_sample,
                        file_size, file_mtime, scanned_at, genre)
    VALUES ('t1', '$wavPath', 'Smoke Song', 1,
            '[{"name":"Smoke Artist"}]', '{"name":"Smoke Album"}', 2000, 'wav',
            44100, 1411200, 1, 16, 176400, 0, 0, 'Smoke');
    CREATE TABLE subsonic_users (
      id TEXT PRIMARY KEY,
      username TEXT NOT NULL UNIQUE,
      password_cipher TEXT NOT NULL,
      is_admin INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL
    );
    CREATE TABLE subsonic_starred (
      user_id TEXT NOT NULL,
      target_id TEXT NOT NULL,
      target_type TEXT NOT NULL,
      starred_at INTEGER NOT NULL,
      PRIMARY KEY (user_id, target_id, target_type)
    );
    CREATE TABLE subsonic_playlists (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      name TEXT NOT NULL,
      comment TEXT,
      public INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );
    CREATE TABLE subsonic_playlist_entries (
      playlist_id TEXT NOT NULL,
      track_id TEXT NOT NULL,
      position INTEGER NOT NULL,
      PRIMARY KEY (playlist_id, position)
    );
    CREATE TABLE subsonic_shares (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      name TEXT NOT NULL,
      description TEXT,
      url TEXT NOT NULL,
      expires_at INTEGER,
      created_at INTEGER NOT NULL,
      visit_count INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE subsonic_share_entries (
      share_id TEXT NOT NULL,
      track_id TEXT NOT NULL,
      PRIMARY KEY (share_id, track_id)
    );
    INSERT INTO subsonic_users (id, username, password_cipher, is_admin, created_at)
    VALUES ('u-legacy', 'legacyuser', '$_legacyCipher', 1, 1700000000000);
    INSERT INTO subsonic_starred (user_id, target_id, target_type, starred_at)
    VALUES ('u-legacy', 't1', 'track', 1700000000001);
    INSERT INTO subsonic_playlists (id, user_id, name, comment, public, created_at, updated_at)
    VALUES ('p-legacy', 'u-legacy', 'Legacy Mix', 'migrated', 0, 1700000000002, 1700000000002);
    INSERT INTO subsonic_playlist_entries (playlist_id, track_id, position)
    VALUES ('p-legacy', 't1', 0);
    INSERT INTO subsonic_shares (id, user_id, name, description, url, expires_at, created_at, visit_count)
    VALUES ('s-legacy', 'u-legacy', 'Legacy Share', 'migrated', 'http://x/ext/share/s-legacy', NULL, 1700000000003, 2);
    INSERT INTO subsonic_share_entries (share_id, track_id)
    VALUES ('s-legacy', 't1');
  ''');
  db.close();
}

/// 迁移验证：user.db 应包含原样搬运的 legacy 数据；library.db 旧 subsonic_* 表已清除。
void _checkMigration(String dbPath, String userDbPath) {
  final udb = sql.sqlite3.open(userDbPath);
  try {
    final users = udb.select(
        "SELECT password_cipher FROM subsonic_users WHERE username = 'legacyuser'");
    if (users.isEmpty) {
      print('FAIL: user.db 未找到迁移的 legacyuser');
      exit(1);
    }
    if (users.first['password_cipher'] != _legacyCipher) {
      print('FAIL: legacyuser 密文未原样搬运: ${users.first['password_cipher']}');
      exit(1);
    }
    final starred = udb.select(
        "SELECT COUNT(*) AS c FROM subsonic_starred WHERE user_id = 'u-legacy'");
    final pl = udb.select(
        "SELECT COUNT(*) AS c FROM subsonic_playlist_entries WHERE playlist_id = 'p-legacy'");
    final shares = udb.select(
        "SELECT COUNT(*) AS c FROM subsonic_share_entries WHERE share_id = 's-legacy'");
    if (starred.first['c'] != 1 || pl.first['c'] != 1 || shares.first['c'] != 1) {
      print('FAIL: 收藏/播放列表/分享迁移不完整: '
          'starred=${starred.first['c']} pl=${pl.first['c']} shares=${shares.first['c']}');
      exit(1);
    }
  } finally {
    udb.close();
  }
  final ldb = sql.sqlite3.open(dbPath);
  try {
    final legacy = ldb.select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'subsonic_%'");
    if (legacy.isNotEmpty) {
      print('FAIL: 媒体库残留旧 subsonic 表: '
          '${legacy.map((r) => r['name']).toList()}');
      exit(1);
    }
  } finally {
    ldb.close();
  }
  print('OK: 自动迁移 legacy 数据 → user.db，媒体库旧表已清理');
}

/// 生成 2 秒 sine WAV（44.1k 16-bit mono）。
void _writeWav(String path, int sampleRate, double seconds) {
  final n = (sampleRate * seconds).round();
  final data = Int16List(n);
  for (var i = 0; i < n; i++) {
    data[i] = (sin(2 * pi * 440 * i / sampleRate) * 12000).round();
  }
  final bytes = ByteData(44 + data.length * 2);
  void w(int off, int v) => bytes.setUint8(off, v & 0xff);
  void w32(int off, int v) {
    bytes.setInt32(off, v, Endian.little);
  }

  w(0, 0x52); w(1, 0x49); w(2, 0x46); w(3, 0x46); // RIFF
  w32(4, 36 + data.length * 2);
  w(8, 0x57); w(9, 0x41); w(10, 0x56); w(11, 0x45); // WAVE
  w(12, 0x66); w(13, 0x6d); w(14, 0x74); w(15, 0x20); // fmt
  w32(16, 16);
  w32(20, 1); // PCM
  w32(22, 1); // mono
  w32(24, sampleRate);
  w32(28, sampleRate * 2); // byte rate
  w32(32, 2); // block align
  w32(34, 16); // bits
  w(36, 0x64); w(37, 0x61); w(38, 0x74); w(39, 0x61); // data
  w32(40, data.length * 2);
  for (var i = 0; i < data.length; i++) {
    bytes.setInt16(44 + i * 2, data[i], Endian.little);
  }
  File(path).writeAsBytesSync(bytes.buffer.asUint8List());
}
