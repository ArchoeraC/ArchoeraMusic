library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archoera_music/services/playback/pcm_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

/// PcmAnalyzer seek 截断重建回归（§B 边解边播 seek 后频谱消失）。
///
/// 流式播放 seek 时引擎以 "wb" 截断重建 stream.pcm（mediaengine_lib.c
/// mediaengine_stream_rebuild），新块从 seek 目标位置重新写入。索引若不
/// 感知截断：_fileEnd 越过新文件末尾 → 新块永不入索引 / 位置回退污染
/// 二分序 / 按旧偏移读到错位数据 → seek 后频谱消失。
///
/// 覆盖三种重置触发：
///   1. 文件变短（total < _fileEnd）——常规截断；
///   2. 位置回退（posMs < _offsets.last）——截断后新文件长过旧 _fileEnd；
///   3. 索引非空时头部非法——重写竞态下 _fileEnd 落在新块载荷内。
void main() {
  late Directory dir;
  late String pcmPath;

  /// 块字节长：12 头 + samples×channels×4。
  int blockBytes(int samples, int channels) => 12 + samples * channels * 4;

  /// 按引擎 on_pcm_out 块格式追加一块：[pos_ms|samples|channels]+float。
  /// 载荷统一填 0.5（0x3F000000，按 int32 读回远大于 8，落在头字段上
  /// 必判非法——用于触发「头部非法」重置路径）。
  void writeBlock(
    RandomAccessFile f, {
    required int posMs,
    required int samples,
    int channels = 2,
  }) {
    final header = ByteData(12)
      ..setInt32(0, posMs, Endian.little)
      ..setInt32(4, samples, Endian.little)
      ..setInt32(8, channels, Endian.little);
    f.writeFromSync(header.buffer.asUint8List());
    final data = Float32List(samples * channels);
    data.fillRange(0, data.length, 0.5);
    f.writeFromSync(data.buffer.asUint8List());
  }

  /// 模拟引擎 seek 重建：截断 stream.pcm 后从新目标位置重写。
  void rebuildPcm(List<(int, int)> blocks, {int channels = 2}) {
    final f = File(pcmPath).openSync(mode: FileMode.write);
    try {
      for (final (posMs, samples) in blocks) {
        writeBlock(f, posMs: posMs, samples: samples, channels: channels);
      }
    } finally {
      f.closeSync();
    }
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pcm-analyzer-test-');
    pcmPath = '${dir.path}/stream.pcm';
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('前向 seek：截断重建（文件变短）→ 索引重置、频谱恢复', () async {
    final f = File(pcmPath).openSync(mode: FileMode.write);
    writeBlock(f, posMs: 0, samples: 480);
    writeBlock(f, posMs: 10, samples: 480);
    writeBlock(f, posMs: 20, samples: 480);
    f.closeSync();

    final a = await PcmAnalyzer.open(pcmPath);
    expect(a.frameAt(15), isNotNull, reason: '截断前应可取帧');
    expect(a.blockCount, 3);

    // 引擎 seek 到 120s：截断重建，新块从 120000ms 起写
    rebuildPcm([(120000, 480), (120010, 480)]);
    a.scan();
    expect(a.blockCount, 2, reason: '回归：截断后旧索引必须清空（曾保留 stale 3 块）');
    expect(a.frameAt(15), isNull, reason: '截断后旧位置不应命中任何索引');
    expect(a.frameAt(120015), isNotNull, reason: 'seek 目标位置须恢复取帧');
    a.dispose();
  });

  test('后向 seek：截断重建（文件变短）→ 频谱恢复', () async {
    final f = File(pcmPath).openSync(mode: FileMode.write);
    writeBlock(f, posMs: 60000, samples: 480);
    writeBlock(f, posMs: 60010, samples: 480);
    f.closeSync();

    final a = await PcmAnalyzer.open(pcmPath);
    expect(a.frameAt(60015), isNotNull);
    expect(a.blockCount, 2);

    // 引擎 seek 回 5s：新块 posMs 小于旧索引首块（位置回退）
    rebuildPcm([(5000, 480)]);
    final frame = a.frameAt(5005);
    expect(frame, isNotNull, reason: '回归：后向 seek 曾因 stale 索引永久返回 null');
    expect(a.blockCount, 1, reason: '重扫后索引应只含新块');
    a.dispose();
  });

  test('后向 seek：截断后新文件长过旧 _fileEnd → 位置回退触发重扫', () async {
    final f = File(pcmPath).openSync(mode: FileMode.write);
    writeBlock(f, posMs: 60000, samples: 480);
    writeBlock(f, posMs: 60010, samples: 480);
    f.closeSync();

    final a = await PcmAnalyzer.open(pcmPath);
    expect(a.frameAt(60015), isNotNull);
    final oldBlocks = a.blockCount;

    // 新文件 3 块 > 旧 2 块：total > _fileEnd，长度探测失效，
    // 只能靠 posMs(5020) < _offsets.last(60010) 识别重建
    rebuildPcm([(5000, 480), (5010, 480), (5020, 480)]);
    expect(File(pcmPath).lengthSync(),
        greaterThan(blockBytes(480, 2) * oldBlocks));

    expect(a.frameAt(5015), isNotNull, reason: '回归：位置回退须触发归零重扫');
    expect(a.blockCount, 3, reason: '重扫后索引应只含新块（无 stale 残留）');
    a.dispose();
  });

  test('重写竞态：旧 _fileEnd 落在新块载荷内（头部非法）→ 重扫恢复', () async {
    // 旧：4 块 × 48000 样本，_fileEnd = 4×384,012 = 1,536,048
    final f = File(pcmPath).openSync(mode: FileMode.write);
    for (var i = 0; i < 4; i++) {
      writeBlock(f, posMs: i * 1000, samples: 48000);
    }
    f.closeSync();

    final a = await PcmAnalyzer.open(pcmPath);
    expect(a.frameAt(35000), isNotNull);
    final oldEnd = a.bytesIn;

    // 新：4 块 × 50000 样本（块长 400,012），总长 1,600,048 > oldEnd：
    // 长度探测失效；旧 _fileEnd 落在第 4 块载荷（样本 42000）内，
    // 头字段读回 0x3F000000 → channels 远大于 8 → 非法块 → 归零重扫
    rebuildPcm(
      [(40000, 50000), (41000, 50000), (42000, 50000), (43000, 50000)],
    );
    expect(File(pcmPath).lengthSync(), greaterThan(oldEnd));

    a.scan();
    expect(a.bytesIn, File(pcmPath).lengthSync(),
        reason: '回归：头部非法兜底须触发重扫（曾停在旧 _fileEnd 不再前进）');
    expect(a.blockCount, 4);
    expect(a.frameAt(43500), isNotNull, reason: 'seek 后位置须可取帧');
    a.dispose();
  });
}
