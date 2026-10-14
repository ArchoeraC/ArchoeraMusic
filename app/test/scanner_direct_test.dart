// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:archoera_music/services/scanner/library_scanner.dart';
import 'package:archoera_music/services/scanner/scanner_ffi.dart';
import 'package:archoera_music/services/scanner/sqlite_preload.dart';
import 'package:archoera_music/services/scanner/tracks_db.dart';

/// 生成最小合法 WAV（44 字节 RIFF header + PCM 静音），TagLib 可解析。
Uint8List makeWav({int sampleRate = 44100, double seconds = 0.2}) {
  final dataLen = (sampleRate * seconds).round() * 2; // 16bit mono
  final b = BytesBuilder();
  void ascii(String s) => b.add(s.codeUnits);
  void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u16(int v) => b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());

  ascii('RIFF');
  u32(36 + dataLen);
  ascii('WAVE');
  ascii('fmt ');
  u32(16); // fmt chunk size
  u16(1); // PCM
  u16(1); // mono
  u32(sampleRate);
  u32(sampleRate * 2); // byte rate
  u16(2); // block align
  u16(16); // bits
  ascii('data');
  u32(dataLen);
  b.add(Uint8List(dataLen));
  return b.toBytes();
}

void main() {
  // 统一 dart sqlite3 与 scanner 的 SQLite 实例（hooks 配置按名 dlopen
  // libe_sqlite3.so，先预加载 dev 目录的内置库，任何 sqlite3.open 之前）。
  preloadBundledSqlite();
  // 定位共享库：dev 兜底 cwd=app/ → app/core/scanner/build/scanner-ffi.so
  final soPath = ScannerLibrary.resolveSoPath();

  test('scanner-ffi 库可加载', () {
    final lib = ScannerLibrary.load(soPath: soPath);
    expect(lib, isNotNull);
  });

  test('FFI 扫描写入 DB + TracksDb 读取', () async {
    final tmp = await Directory.systemTemp.createTemp('scanner_test');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final musicDir = '${tmp.path}/music';
    Directory(musicDir).createSync(recursive: true);
    File('$musicDir/t1.wav').writeAsBytesSync(makeWav());
    File('$musicDir/t2.wav').writeAsBytesSync(makeWav(seconds: 0.3));
    File('$musicDir/note.txt').writeAsStringSync('not audio'); // 应被忽略

    final dbPath = '${tmp.path}/data/library.db';

    final scanner = LibraryScanner(soPath: soPath);
    addTearDown(scanner.dispose);

    final progress = <ScanProgress>[];
    final sub = scanner.progress.listen(progress.add);
    addTearDown(() => sub.cancel());

    final result = await scanner.scan([musicDir], dbPath: dbPath);

    expect(result.errors, 0);
    expect(result.upserted, 2);
    expect(result.total, 2); // txt 不计入
    expect(progress, isNotEmpty); // 至少一帧进度

    // 读库
    final db = TracksDb.open(dbPath);
    addTearDown(db.close);
    expect(db.count(), 2);

    final tracks = db.listTracks();
    expect(tracks.length, 2);
    final t = tracks.first;
    expect(t.path, startsWith(musicDir));
    expect(t.title, isNotEmpty);
    expect(t.durationMs, greaterThan(0));

    // 二次增量：文件未变应全跳过
    final result2 = await scanner.scan([musicDir], dbPath: dbPath);
    expect(result2.upserted, 0);
  });

  test('伪造/空壳音频（有体积但无实际内容）被拒绝入库', () async {
    final tmp = await Directory.systemTemp.createTemp('scanner_fake');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final musicDir = '${tmp.path}/music';
    Directory(musicDir).createSync(recursive: true);
    // 合法样本 + 两类「有体积但实际内容为 0」的伪造/空壳：
    File('$musicDir/ok.wav').writeAsBytesSync(makeWav());
    // 1) 全 0 字节内容、伪装成 .mp3（无任何音频帧）
    File('$musicDir/zero.mp3').writeAsBytesSync(Uint8List(64 * 1024));
    // 2) 合法 RIFF/fmt 头但 data 段长度为 0（无音频帧）
    File('$musicDir/empty.wav').writeAsBytesSync(makeWav(seconds: 0));

    final dbPath = '${tmp.path}/data/library.db';
    final scanner = LibraryScanner(soPath: soPath);
    addTearDown(scanner.dispose);

    final result = await scanner.scan([musicDir], dbPath: dbPath);
    expect(result.total, 3, reason: '三个 .wav/.mp3 均被发现');
    expect(result.upserted, 1, reason: '仅合法样本入库');
    expect(result.errors, 2, reason: '伪造/空壳文件按解析失败拒绝（empty_audio/taglib_error）');

    final db = TracksDb.open(dbPath);
    addTearDown(db.close);
    expect(db.count(), 1, reason: '曲库不含伪造内容');
  });

  test('侧车歌词：GBK / GB18030(四字节) / UTF-16LE 解码入 DB（AOT 回归）', () async {
    // 回归点：`.lrc` 解码走「BOM → 严格 UTF-8 → **GB18030**（框架 CodePages）→ UTF-8 替换」，
    // 而 GB18030 是**动态字符串取编码 + 进程级 RegisterProvider**，NativeAOT 裁剪下最容易被
    // 悄悄弄坏（编码表被裁掉后只会在运行时抛/退化成乱码）。本用例跑在 **AOT 产物**
    // （`scanner/build/scanner-ffi.so`）上，字节序列**硬编码**（不依赖 Dart 侧编码库）。
    final tmp = await Directory.systemTemp.createTemp('scanner_sidecar');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final musicDir = '${tmp.path}/music';
    Directory(musicDir).createSync(recursive: true);
    File('$musicDir/gbk.wav').writeAsBytesSync(makeWav());
    File('$musicDir/gb18030.wav').writeAsBytesSync(makeWav(seconds: 0.3));
    File('$musicDir/utf16.wav').writeAsBytesSync(makeWav(seconds: 0.4));
    File('$musicDir/utf8.wav').writeAsBytesSync(makeWav(seconds: 0.5));

    // GBK：「月亮代表我的心」（双字节，GBK ⊂ GB18030）
    File('$musicDir/gbk.lrc').writeAsBytesSync([
      0x5B, 0x30, 0x30, 0x3A, 0x30, 0x31, 0x2E, 0x30, 0x30, 0x5D, // [00:01.00]
      0xD4, 0xC2, 0xC1, 0xC1, 0xB4, 0xFA, 0xB1, 0xED, 0xCE, 0xD2, 0xB5, 0xC4, 0xD0, 0xC4,
      0x0A,
    ]);
    // GB18030 四字节：U+20000（𠀀）—— 只有 GB18030 能解，验证不是「只做 GBK 双字节」
    File('$musicDir/gb18030.lrc').writeAsBytesSync([
      0x5B, 0x30, 0x30, 0x3A, 0x30, 0x31, 0x2E, 0x30, 0x30, 0x5D,
      0x95, 0x32, 0x82, 0x36,
      0x0A,
    ]);
    // UTF-16LE + BOM：「轻轻地」（U+8F7B / U+5730 → LE 0x7B8F / 0x3057）
    File('$musicDir/utf16.lrc').writeAsBytesSync([
      0xFF, 0xFE, // BOM
      0x5B, 0x00, 0x30, 0x00, 0x30, 0x00, 0x3A, 0x00, 0x30, 0x00, 0x31, 0x00, 0x2E, 0x00,
      0x30, 0x00, 0x30, 0x00, 0x5D, 0x00, // [00:01.00]
      0x7B, 0x8F, 0x7B, 0x8F, 0x30, 0x57, // 轻轻地
      0x0A, 0x00,
    ]);
    // UTF-8（严格试解码路径）
    File('$musicDir/utf8.lrc').writeAsStringSync('[00:01.00]你好世界\n');

    final dbPath = '${tmp.path}/data/library.db';
    final scanner = LibraryScanner(soPath: soPath);
    addTearDown(scanner.dispose);
    final result = await scanner.scan([musicDir], dbPath: dbPath);
    expect(result.errors, 0, reason: '侧车编码差异不应导致解析失败');
    expect(result.upserted, 4);

    final db = TracksDb.open(dbPath);
    addTearDown(db.close);
    expect(db.lyricsByPath('$musicDir/gbk.wav'), '[00:01.00]月亮代表我的心\n',
        reason: 'GBK 双字节（框架 CodePages）在 AOT 产物里必须仍然可用');
    expect(db.lyricsByPath('$musicDir/gb18030.wav'), '[00:01.00]\u{20000}\n',
        reason: 'GB18030 四字节序列');
    expect(db.lyricsByPath('$musicDir/utf16.wav'), '[00:01.00]轻轻地\n',
        reason: 'UTF-16LE + BOM');
    expect(db.lyricsByPath('$musicDir/utf8.wav'), '[00:01.00]你好世界\n',
        reason: '严格 UTF-8 试解码路径');
  });

  test('DB 不存在时打开抛错', () {
    final tmp = Directory.systemTemp.createTempSync('scanner_test_nodb');
    final dbPath = '${tmp.path}/missing/library.db';
    expect(
      () => TracksDb.open(dbPath),
      throwsA(anything),
    );
    tmp.deleteSync(recursive: true);
  });
}
