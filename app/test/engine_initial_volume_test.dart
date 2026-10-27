// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 引擎会话初始音量（EngineConfig.initial_volume）：
// 建会话时就要带上用户音量，避免首块 PCM 先按满音量出声（第 0 秒爆音）。

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:archoera_music/services/playback/engine_bindings.dart';

void main() {
  test('初始音量：默认 1.0、按参数透传、越界夹取到 0~1', () {
    double read(double? value) {
      final cfg = engineConfigFromParams(initialVolume: value ?? 1.0);
      try {
        return cfg.ref.initialVolume;
      } finally {
        calloc.free(cfg);
      }
    }

    expect(read(null), 1.0);
    expect(read(0.25), 0.25);
    expect(read(0.0), 0.0);
    expect(read(1.8), 1.0);
    expect(read(-0.5), 0.0);
  });
}
