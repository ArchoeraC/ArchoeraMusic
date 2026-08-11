import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'fft_bindings.dart';
import 'fft_frame.dart';

/// PCM 文件读取器 + 按需 FFT 分析器（§10.1 拉模式）。
///
/// 引擎全速转码（无播放背压）时，原始 float PCM 由引擎**直写会话目录
/// `stream.pcm`**（块格式，同 pcm_uds，不再经 socket 传输）。本类：
///  1. [scan] 增量扫描文件块头，内存记录 (posMs → 文件偏移) 索引；
///  2. [frameAt] 按播放位置二分索引 → 取「以当前位置为终点的最近
///     fftSize 样本」窗口（跨块读取 + 按源声道布局下混）→ 帧直算 FFT。
///
/// 引擎转码可快于实时，UI 必须按引擎实际播放位置取帧，故按需计算
/// 而非缓冲全量帧（长音频全量缓冲内存不可接受）。
///
/// 取帧语义对齐原 SPlayer-Next Rust 端 analyze()（环形缓冲取最新
/// fft_size 样本直接算一帧），与 C 侧流式累积器（fft_process_multi，
/// 供实时播放线程持续喂样本）解耦——按位置随机取帧时不受累积状态影响。
///
/// 块格式（引擎 mediaengine_lib.c on_pcm_out，小端）：
///   [pos_ms int32][samples int32][channels int32] + samples×channels×4 字节 float
class PcmAnalyzer {
  PcmAnalyzer._(this._raf, this._fft, this._sampleRate) {
    _l = Float64List(_fft.fftSize);
    _r = Float64List(_fft.fftSize);
  }

  /// 打开已存在（或正在写入）的 PCM 文件。文件未写完时 [scan]/[frameAt]
  /// 按当前文件大小增量处理，转码完成后再调用 [scan] 补全索引。
  static Future<PcmAnalyzer> open(String path, {int sampleRate = 48000}) async {
    final raf = await File(path).open(mode: FileMode.read);
    return PcmAnalyzer._(raf, FftAnalyzer(sampleRate: sampleRate), sampleRate);
  }

  final RandomAccessFile _raf;
  final FftAnalyzer _fft;
  final int _sampleRate;

  /// 每块起始时间（ms）。
  final List<int> _offsets = [];

  /// 每块在 PCM 文件中的字节偏移（含 12 字节块头）。
  final List<int> _fileOffsets = [];

  /// 每块样本数（每声道）。
  final List<int> _blockSamples = [];

  /// 每块起始样本索引（全局，跨块累积）。
  final List<int> _sampleStarts = [];

  /// 已扫描到的文件偏移（增量游标）。
  int _fileEnd = 0;

  /// 已累积样本总数（跨块；_sampleStarts 计算用）。
  int _sampleCount = 0;

  /// 已扫描块数（诊断）。
  int get blockCount => _offsets.length;

  /// 已扫描文件字节数（诊断，引擎直写进度）。
  int get bytesIn => _fileEnd;

  /// 窗口样本缓冲（复用，避免每帧分配；帧直算同步消费后即返回）。
  late final Float64List _l;
  late final Float64List _r;

  /// 增量扫描文件新追加的 PCM 块（引擎直写中调用也安全）。
  void scan() {
    final total = _raf.lengthSync();
    while (_fileEnd + 12 <= total) {
      _raf.setPositionSync(_fileEnd);
      final header = _raf.readSync(12);
      final bd = ByteData.sublistView(header);
      final posMs = bd.getInt32(0, Endian.little);
      final samples = bd.getInt32(4, Endian.little);
      final channels = bd.getInt32(8, Endian.little);
      if (samples <= 0 || channels <= 0 || channels > 8) break; // 异常块，停止
      final need = samples * channels * 4;
      if (_fileEnd + 12 + need > total) break; // 块未写完，等下次扫描
      _offsets.add(posMs);
      _fileOffsets.add(_fileEnd);
      _blockSamples.add(samples);
      _sampleStarts.add(_sampleCount);
      _sampleCount += samples;
      _fileEnd += 12 + need;
    }
  }

  /// 按播放位置取最近一帧（窗口终点 = posMs，向前 fftSize 样本；
  /// 位置早于首块返回 null）。
  ///
  /// 按需从 PCM 文件读取窗口（可跨块）并下混为左右声道后直算 FFT：
  /// 内存仅保留索引，任意位置可回溯（seek 友好）。
  FftFrame? frameAt(int posMs) {
    scan(); // 文件可能仍在增长，先补全索引
    if (_blockSamples.isEmpty) return null;

    // 1) 定位 posMs 所在块（offset ≤ posMs 的最后一个）
    var bi = _upperBoundOffsets(posMs) - 1;
    if (bi < 0) return null;

    // 2) 窗口终点样本 = 块内 posMs 时刻（块起始毫秒 + 块内偏移 × 采样率）
    final bs = _blockSamples[bi];
    var inBlock = ((posMs - _offsets[bi]) * _sampleRate / 1000).round();
    if (inBlock >= bs) inBlock = bs - 1;
    if (inBlock < 0) inBlock = 0;
    final endSample = _sampleStarts[bi] + inBlock;

    // 3) 窗口 [endSample - fftSize + 1, endSample]（起点不足则前缀补零）
    final size = _fft.fftSize;
    final startSample = endSample - size + 1;
    _l.fillRange(0, size, 0.0); // 清空（前缀/尾部补零基于此）
    _r.fillRange(0, size, 0.0);

    var fill = 0;
    var si = startSample;
    if (startSample < 0) {
      fill = -startSample; // 前缀补零（已清空），数据从样本 0 开始
      si = 0;
    }
    var bi2 = _blockIndexOfSample(si);
    while (fill < size && bi2 >= 0 && bi2 < _blockSamples.length) {
      final bStart = si - _sampleStarts[bi2];
      if (bStart < 0) {
        bi2++;
        continue;
      }
      final avail = _blockSamples[bi2] - bStart;
      if (avail <= 0) {
        bi2++;
        continue;
      }
      final take = min(avail, size - fill);
      _readBlockDownmix(bi2, bStart, take, _l, _r, fill);
      fill += take;
      si += take;
      bi2++;
    }
    if (fill <= 0) return null;

    // 4) 帧直算（C 侧对不足 fftSize 的尾部补零）
    return _fft.processFrame(_l, _r, fill);
  }

  /// 二分 _offsets：第一个 > posMs 的索引。
  int _upperBoundOffsets(int posMs) {
    var lo = 0, hi = _offsets.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_offsets[mid] <= posMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// 样本索引 s 所在块（_sampleStarts[i] ≤ s < _sampleStarts[i] + samples[i]）；
  /// 越界返回 -1 / _blockSamples.length。
  int _blockIndexOfSample(int s) {
    if (s < 0 || _sampleStarts.isEmpty) return -1;
    var lo = 0, hi = _sampleStarts.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_sampleStarts[mid] <= s) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo - 1;
  }

  /// 读取块 [start, start+take) 样本并下混为左右声道，写入 [fill, fill+take)。
  void _readBlockDownmix(
    int bi,
    int start,
    int take,
    Float64List l,
    Float64List r,
    int fill,
  ) {
    try {
      final foff = _fileOffsets[bi];
      _raf.setPositionSync(foff);
      final header = _raf.readSync(12);
      final bd = ByteData.sublistView(header);
      final samples = bd.getInt32(4, Endian.little);
      final channels = bd.getInt32(8, Endian.little);
      if (channels <= 0 || channels > 8) return;
      if (start >= samples) return;
      if (start + take > samples) take = samples - start;
      _raf.setPositionSync(foff + 12 + start * channels * 4);
      final data = _raf.readSync(take * channels * 4);
      final f = Float32List.sublistView(data);
      for (var i = 0; i < take; i++) {
        final (ll, rr) = _downmix(f, i, channels);
        l[fill + i] = ll;
        r[fill + i] = rr;
      }
    } catch (_) {
      // 读取失败（文件截断等）：跳过该块
    }
  }

  /// 交织样本按声道布局下混为左右声道（对齐 C fft_process_multi，
  /// ITU-R BS.775 下混系数；1~6ch，超出退化取前两声道）。
  static (double, double) _downmix(Float32List d, int i, int channels) {
    switch (channels) {
      case 1:
        return (d[i], d[i]);
      case 2:
        return (d[2 * i], d[2 * i + 1]);
      case 3: // L R C
        return (
          d[3 * i] + _invSqrt2 * d[3 * i + 2],
          d[3 * i + 1] + _invSqrt2 * d[3 * i + 2],
        );
      case 4: // FL FR BL BR
        return (
          d[4 * i] + _invSqrt2 * d[4 * i + 2],
          d[4 * i + 1] + _invSqrt2 * d[4 * i + 3],
        );
      case 5: // L R C BL BR
        return (
          d[5 * i] + _invSqrt2 * d[5 * i + 2] + _invSqrt2 * d[5 * i + 3],
          d[5 * i + 1] + _invSqrt2 * d[5 * i + 2] + _invSqrt2 * d[5 * i + 4],
        );
      case 6: // 5.1：LFE 不入下混
        return (
          d[6 * i] + _invSqrt2 * d[6 * i + 2] + _invSqrt2 * d[6 * i + 4],
          d[6 * i + 1] + _invSqrt2 * d[6 * i + 2] + _invSqrt2 * d[6 * i + 5],
        );
      default:
        return (
          d[channels * i],
          channels >= 2 ? d[channels * i + 1] : d[channels * i],
        );
    }
  }

  static const double _invSqrt2 = 0.70710678;

  void dispose() {
    try {
      _raf.closeSync();
    } catch (_) {}
    _fft.dispose();
    _offsets.clear();
    _fileOffsets.clear();
    _blockSamples.clear();
    _sampleStarts.clear();
  }
}
