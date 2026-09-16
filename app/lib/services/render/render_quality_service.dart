// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ui' show FrameTiming;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../stores/app_prefs.dart';
import 'quality_governor.dart';

/// 档位 → 动态层渲染尺度（`RippleBackground.renderScale`）的纯映射
/// （见 docs/runtime-resource-optimization.md §4.5 / R4）。
///
/// `full → 1.0`（默认，不产生额外离屏分配）、`balanced → 0.85`、
/// `performance → 0.7`。纯函数，便于单测；不依赖 binding。
double renderScaleForTier(RenderQualityTier tier) => switch (tier) {
  RenderQualityTier.full => 1.0,
  RenderQualityTier.balanced => 0.85,
  RenderQualityTier.performance => 0.7,
};

/// 自适应画质服务：把真实 [FrameTiming] 喂给 [QualityGovernor]，并把当前档位
/// 以 [tierListenable] 暴露给 UI（`player_background.dart` 据此设置
/// `RippleBackground.renderScale`）。
///
/// 默认**停用**：构造后 [enabled] 为 false，不注册任何回调、不动 Governor，
/// 因此对现有行为零影响。开启时经 [SchedulerBinding.addTimingsCallback] 接收
/// 每批帧时间（事件驱动，无轮询）；停用时注销回调并把 Governor 复位到
/// [RenderQualityTier.full]。
class RenderQualityService {
  RenderQualityService({QualityGovernor? governor})
    : _governor = governor ?? QualityGovernor() {
    _tier.value = _governor.tier;
  }

  final QualityGovernor _governor;
  final ValueNotifier<RenderQualityTier> _tier = ValueNotifier(
    RenderQualityTier.full,
  );

  bool _enabled = false;

  /// 当前档位（默认 [RenderQualityTier.full]）。
  ValueListenable<RenderQualityTier> get tierListenable => _tier;

  /// 同步读取当前档位。
  RenderQualityTier get tier => _tier.value;

  /// 是否已启用帧时间采集。
  bool get enabled => _enabled;

  /// 启用 / 停用。开启时注册帧时间回调；停用时注销回调并把 Governor 复位到
  /// [RenderQualityTier.full]（档位随之广播）。
  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    final binding = SchedulerBinding.instance;
    if (value) {
      binding.addTimingsCallback(_onTimings);
    } else {
      binding.removeTimingsCallback(_onTimings);
      _governor.reset();
      _tier.value = _governor.tier;
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    if (!_enabled) return;
    for (final timing in timings) {
      _governor.record(timing);
    }
    if (_tier.value != _governor.tier) {
      _tier.value = _governor.tier;
    }
  }

  /// 释放：停用（若开启）并释放 Governor 与档位通知。
  void dispose() {
    if (_enabled) {
      _enabled = false;
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    }
    _governor.dispose();
    _tier.dispose();
  }
}

/// 当前渲染画质档位（应用级单例，随 ProviderScope 存活）。
///
/// 非 autoDispose：首次被读取后即常驻，服务与 Governor 随之长活。build 内
/// 读取 `adaptiveRenderQuality` 偏好并 `fireImmediately` 接线，偏好变更即时
/// 启用 / 停用服务。
final renderQualityProvider =
    NotifierProvider<RenderQualityController, RenderQualityTier>(
      RenderQualityController.new,
    );

class RenderQualityController extends Notifier<RenderQualityTier> {
  RenderQualityService? _service;

  @override
  RenderQualityTier build() {
    final service = RenderQualityService();
    _service = service;
    service.tierListenable.addListener(_onTierChanged);
    ref.onDispose(() {
      service.tierListenable.removeListener(_onTierChanged);
      service.dispose();
    });
    ref.listen(
      appPrefsProvider.select((p) => p.adaptiveRenderQuality),
      (_, enabled) => service.setEnabled(enabled),
      fireImmediately: true,
    );
    return service.tier;
  }

  void _onTierChanged() {
    final tier = _service?.tier;
    if (tier != null && tier != state) state = tier;
  }

  /// 底层服务（调试 / 测试用）。
  RenderQualityService get service => _service!;
}
