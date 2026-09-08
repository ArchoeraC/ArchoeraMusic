// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// M2.2 内存门禁决策纯函数测试：故意压低内存（ARCHOERA_MEMORY_CEIL_MB / FLOOR_MB）
// 观察决策（整首可驻留 ⇄ 回退 URL 路径），无需引擎/网络。
import 'package:archoera_music/services/playback/store_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('默认（未压低）：整首驻留上限为 64 MiB', () {
    // env 不注入 → 读取进程真实 env；未设置时回落默认。
    expect(
      memoryWholeTrackLimitBytes(env: const {}),
      kMemorySourceWholeTrackLimit,
    );
  });

  test('故意压低：ceiling 8MiB、floor 默认 32MiB → 缓存区 0（任何在线曲不可纯内存）', () {
    final limit = memoryWholeTrackLimitBytes(
      env: const {'ARCHOERA_MEMORY_CEIL_MB': '8'},
    );
    expect(limit, 0, reason: '8MiB - 32MiB(floor) ≤ 0 → 直接判定不可用');
    final explain = memoryGateExplain(
      1 << 20,
      env: const {'ARCHOERA_MEMORY_CEIL_MB': '8'},
    );
    expect(explain, contains('回退 URL 路径'));
  });

  test('故意压低：ceiling 48MiB - floor 32MiB → 仅 ≤16MiB 曲可整首驻留', () {
    final env = const {
      'ARCHOERA_MEMORY_CEIL_MB': '48',
      'ARCHOERA_MEMORY_FLOOR_MB': '32',
    };
    expect(memoryWholeTrackLimitBytes(env: env), 16 << 20);
    expect(memoryGateExplain(8 << 20, env: env), contains('整首可驻留'));
    expect(memoryGateExplain(20 << 20, env: env), contains('回退 URL 路径'));
  });

  test('floor 覆盖：ceiling 64MiB + floor 1MiB → 63MiB 缓存区', () {
    final env = const {
      'ARCHOERA_MEMORY_CEIL_MB': '64',
      'ARCHOERA_MEMORY_FLOOR_MB': '1',
    };
    expect(memoryWholeTrackLimitBytes(env: env), 63 << 20);
  });
}
