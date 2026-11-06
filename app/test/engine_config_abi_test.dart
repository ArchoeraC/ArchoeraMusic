// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// `EngineConfig` C ABI 布局守卫（docs/spectrum-analyzer.md §2.1）。
///
/// Dart 侧 [EngineConfigC] 必须与 `app/core/audio-engine/include/audio_engine.h`
/// 的 `EngineConfig` 逐字段一致。频谱 v1 删除时 C 侧移除了 `fft_enabled` /
/// `fft_size`，Dart 结构体若残留这两个字段，其后所有字段整体偏移 8 字节：
/// `tempo_*` / `engine_mode` / `no_disk_cache` / `pcm_mem_cap_kb` /
/// `initial_volume` 全部读错位——实测表现为「内存播放上限被读成 1 KB」，
/// 频谱取窗永远失败（可视化空白），EraAudio 偏好失效、初始音量读成 0。
///
/// 本测试直接从 C 头文件复算 `EngineConfig` 的偏移与总大小，再用哨兵值写入
/// 原生内存后经 Dart 访问器读回；C 侧增删/重排字段而 Dart 未同步时立即失败。
/// 纯静态分析 + FFI 布局，不需要任何原生产物。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/playback/engine_bindings.dart';

/// 从 `audio_engine.h` 复算 `EngineConfig` 的字段偏移（C 标准对齐规则）。
Map<String, int> _cFieldOffsets(String source, {required int bytes}) {
  final start = source.indexOf('typedef struct {', source.indexOf('引擎配置'));
  expect(start, greaterThanOrEqualTo(0), reason: '未找到 EngineConfig 结构体');
  final end = source.indexOf('} EngineConfig;', start);
  expect(end, greaterThan(start), reason: '未找到 EngineConfig 结尾');

  final block = source.substring(start + 'typedef struct {'.length, end);
  final fields = <String, int>{};
  var offset = 0;
  var maxAlign = 1;
  final re = RegExp(
    r'^\s*(int64_t|int|float|bool)\s+(\w+)\s*(?:\[\s*(\w+)\s*\])?\s*;',
    multiLine: true,
  );
  for (final m in re.allMatches(block)) {
    final type = m.group(1)!;
    final name = m.group(2)!;
    final countRaw = m.group(3);
    var count = 1;
    if (countRaw != null) {
      final literal = int.tryParse(countRaw);
      if (literal == null) {
        final def = RegExp('#define\\s+$countRaw\\s+(\\d+)').firstMatch(source);
        expect(def, isNotNull, reason: '未找到数组长度宏 $countRaw');
        count = int.parse(def!.group(1)!);
      } else {
        count = literal;
      }
    }
    final (size, align) = switch (type) {
      'int64_t' => (8, 8),
      'int' => (4, 4),
      'float' => (4, 4),
      _ => (1, 1),
    };
    if (align > maxAlign) maxAlign = align;
    offset = (offset + align - 1) ~/ align * align;
    fields[name] = offset;
    offset += size * count;
  }
  fields['__size__'] = (offset + maxAlign - 1) ~/ maxAlign * maxAlign;
  expect(bytes, fields['__size__'], reason: '结构体总大小与 C 头不一致');
  return fields;
}

void main() {
  late Map<String, int> off;
  late Pointer<EngineConfigC> cfg;
  late ByteData view;

  setUpAll(() {
    final candidates = [
      'core/audio-engine/include/audio_engine.h',
      '../core/audio-engine/include/audio_engine.h',
    ];
    final path = candidates.firstWhere(
      (p) => File(p).existsSync(),
      orElse: () => candidates.first,
    );
    final source = File(path).readAsStringSync();
    off = _cFieldOffsets(source, bytes: sizeOf<EngineConfigC>());

    cfg = calloc<EngineConfigC>();
    view = ByteData.sublistView(
      cfg.cast<Uint8>().asTypedList(sizeOf<EngineConfigC>()),
    );
  });

  tearDownAll(() => calloc.free(cfg));

  /// 在 C 复算出的偏移写入哨兵，确认 Dart 访问器读到的就是该位置。
  test('字段偏移与 audio_engine.h 一致（哨兵写入/读回）', () {
    view.setFloat32(off['limiter_threshold_db']!, -3.5, Endian.host);
    view.setUint8(off['tempo_enabled']!, 1);
    view.setFloat32(off['tempo_speed']!, 1.5, Endian.host);
    view.setFloat32(off['tempo_pitch']!, -2.25, Endian.host);
    view.setUint8(off['tempo_pitch_sync']!, 1);
    view.setInt32(off['engine_mode']!, 1, Endian.host);
    view.setInt32(off['no_disk_cache']!, 1, Endian.host);
    view.setInt64(off['pcm_mem_cap_kb']!, -1, Endian.host);
    view.setFloat32(off['initial_volume']!, 0.25, Endian.host);

    final r = cfg.ref;
    expect(r.limiterThresholdDb, closeTo(-3.5, 1e-6));
    expect(r.tempoEnabled, isTrue);
    expect(r.tempoSpeed, closeTo(1.5, 1e-6));
    expect(r.tempoPitch, closeTo(-2.25, 1e-6));
    expect(r.tempoPitchSync, isTrue);
    expect(r.engineMode, 1, reason: 'EraAudio 偏好必须落到 C 的 engine_mode');
    expect(r.noDiskCache, 1);
    // 关键回归：内存播放上限不得被错位读成 1 KB（会让频谱取窗永远失败）。
    expect(r.pcmMemCapKb, -1);
    expect(r.initialVolume, closeTo(0.25, 1e-6));
  });

  test('配置构造器逐字段写入，C 视角读回一致', () {
    final p = engineConfigFromParams(
      engineMode: 1,
      noDiskCache: 1,
      pcmMemCapKb: 0,
      initialVolume: 0.75,
      tempoSpeed: 1.25,
      tempoPitch: 3,
    );
    try {
      final r = p.ref;
      expect(r.engineMode, 1);
      expect(r.noDiskCache, 1);
      expect(r.pcmMemCapKb, 0, reason: '0 = auto（32 MiB 有界窗口），不是 1 KB');
      expect(r.initialVolume, closeTo(0.75, 1e-6));
      expect(r.tempoEnabled, isTrue);
      expect(r.tempoSpeed, closeTo(1.25, 1e-6));
      expect(r.tempoPitch, closeTo(3, 1e-6));
      expect(r.tempoPitchSync, isTrue);
    } finally {
      calloc.free(p);
    }
  });
}
