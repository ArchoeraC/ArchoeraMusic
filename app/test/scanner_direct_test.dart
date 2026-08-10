import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:archoera_music/services/scanner/library_scanner.dart';
import 'package:archoera_music/services/scanner/scanner_ffi.dart';
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
