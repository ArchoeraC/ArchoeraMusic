// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 行纵向滚动弹簧策略（移植自 AMLL `lyric-player/base/spring.ts`）。
///
/// 上游在**正常播放**时并不是用一套固定弹簧，而是**按当前行与上一行的
/// 时间差自适应**：间隔越短（歌词越密、换行越快）刚度越高、跟得越紧；
/// 间隔越长越柔和。阻尼始终取 `√stiffness × 2.2`，即阻尼比 ζ≈1.1
/// （略过阻尼、**不过冲**），所以高速换行不会来回弹。
///
/// 另外两个特例：Seek / 间奏用慢速参数，歌曲末尾用中速参数。
///
/// 纯 Dart（仅 `dart:math` + `SpringParams`），可单测。
library;

import 'dart:math' as math;

import 'spring.dart';

/// 缓慢模式刚度（Seek / 间奏 / 首尾边界）。
const double kSlowSpringStiffness = 90;

/// 缓慢模式阻尼。
const double kSlowSpringDamping = 15;

/// 中速模式刚度（歌曲播放完毕）。
const double kMediumSpringStiffness = 140;

/// 中速模式阻尼。
const double kMediumSpringDamping = 22;

/// 自适应区间的下限（毫秒）。
const int kSpringMinIntervalMs = 100;

/// 自适应区间的上限（毫秒）。
const int kSpringMaxIntervalMs = 800;

/// 自适应刚度下限（间隔 800ms 以上）。
const double kSpringMinStiffness = 170;

/// 自适应刚度上限（间隔 100ms 及以内）。
const double kSpringMaxStiffness = 220;

/// 阻尼 = √刚度 × 该系数（ζ≈1.1，略过阻尼、不过冲）。
const double kSpringDampingMultiplier = 2.2;

/// 间隔映射的开方指数（0.2 = 五次方根，让 ratio 偏大 → 偏向更快）。
const double kSpringIntervalExponent = 0.2;

/// 行纵向弹簧质量（不随策略变化，与上游一致）。
const double kLineSpringMass = 0.9;

/// 解算行纵向弹簧参数。
///
/// [seeking] 是否处于跳转状态；[interludeActive] 是否处于间奏；
/// [intervalMs] 当前行与上一行的时间差（首行为 null）；
/// [endOfSong] 是否已播放完毕。
SpringParams resolvePosYSpringPolicy({
  bool seeking = false,
  bool interludeActive = false,
  int? intervalMs,
  bool endOfSong = false,
}) {
  // Seek 与间奏：慢速（看得清落点）。
  if (seeking || interludeActive) {
    return const SpringParams(
      mass: kLineSpringMass,
      damping: kSlowSpringDamping,
      stiffness: kSlowSpringStiffness,
    );
  }
  // 播放完毕：中速。
  if (endOfSong) {
    return const SpringParams(
      mass: kLineSpringMass,
      damping: kMediumSpringDamping,
      stiffness: kMediumSpringStiffness,
    );
  }
  // 首行 / 末行等无间隔场景：慢速兜底。
  if (intervalMs == null) {
    return const SpringParams(
      mass: kLineSpringMass,
      damping: kSlowSpringDamping,
      stiffness: kSlowSpringStiffness,
    );
  }

  final clamped = intervalMs.clamp(kSpringMinIntervalMs, kSpringMaxIntervalMs);
  // 间隔越短 → ratio 越接近 1 → 刚度越高。
  var ratio =
      1 -
      (clamped - kSpringMinIntervalMs) /
          (kSpringMaxIntervalMs - kSpringMinIntervalMs);
  ratio = math.pow(ratio, kSpringIntervalExponent).toDouble();

  final stiffness =
      kSpringMinStiffness + ratio * (kSpringMaxStiffness - kSpringMinStiffness);
  return SpringParams(
    mass: kLineSpringMass,
    damping: math.sqrt(stiffness) * kSpringDampingMultiplier,
    stiffness: stiffness,
  );
}
