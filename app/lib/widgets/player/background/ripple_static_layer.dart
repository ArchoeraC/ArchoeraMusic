// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 水纹背景的**静态层**：封面预烘焙（模糊 + 饱和）纹理及其生命周期。
///
/// 预烘焙只在封面变化 / 模糊参数变化时执行一次，之后跨帧复用；每帧涟漪折射与
/// 高光由动态层（见 `ripple_dynamic_layer.dart`）负责。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'blurred_cover.dart';

/// 持有预烘焙封面纹理与「未就绪」回退滤镜的静态层。
class RippleStaticLayer {
  RippleStaticLayer({
    required this.isMounted,
    required this.rebuild,
    required this.blurSigma,
    required this.saturation,
  });

  /// 宿主是否仍挂载（预烘焙微任务前的守卫）。
  final bool Function() isMounted;

  /// 触发宿主重建（传入 `State.setState`）。
  final void Function(VoidCallback fn) rebuild;

  /// 整体模糊半径（px）。
  double blurSigma;

  /// 饱和度。
  double saturation;

  ui.Image? _current;
  ui.Image? _old;

  /// 当前预烘焙纹理。
  ui.Image? get current => _current;

  /// 交叉淡入时的旧预烘焙纹理。
  ui.Image? get old => _old;

  /// 预烘焙：封面 → 模糊 + 饱和纹理（一次，替代每帧全屏模糊）。
  ///
  /// 用同步 [ui.Picture.toImageSync]：`toImage` 为异步，在 widget 测试的
  /// fake-async 环境下会产出空白图；`toImageSync` 同步光栅化，测试/真机一致。
  ui.Image? prepare(ui.Image src, double blurSigma, double saturation) {
    // flutter test 的 fake-async 环境无法光栅化 Picture.toImage(Sync)（会得空白
    // 纹理）；测试统一走「原图 + 每帧滤镜」回退（见宿主 build）。
    if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: blurSigma,
        sigmaY: blurSigma,
      )
      ..colorFilter = saturationColorFilter(saturation);
    canvas.drawImage(src, Offset.zero, paint);
    final pic = recorder.endRecording();
    try {
      return pic.toImageSync(src.width, src.height);
    } catch (_) {
      return null;
    } finally {
      pic.dispose();
    }
  }

  /// 从源封面生成预烘焙纹理并换入当前槽（[transition] 时保留旧纹理做交叉淡入）。
  void prepareCover(ui.Image img, {required bool transition}) {
    // 延后到微任务再 setState，避免在 image 回调（可能处于构建期）同步 setState。
    unawaited(Future<void>.microtask(() {
      if (!isMounted()) return;
      final prepared = prepare(img, blurSigma, saturation);
      if (prepared == null) return;
      final old = _current;
      rebuild(() {
        if (transition && old != null) {
          disposeLater(_old);
          _old = old; // 转移所有权给旧槽
        } else {
          disposeLater(_old);
          _old = null;
          disposeLater(old);
        }
        _current = prepared;
      });
    }));
  }

  /// 交叉淡入结束：旧纹理可释放。
  void releaseOld() {
    disposeLater(_old);
    _old = null;
  }

  /// 延后一帧释放，避免当前帧仍被 sampler/绘制引用。
  void disposeLater(ui.Image? img) {
    if (img == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => img.dispose());
  }

  /// 预烘焙未就绪时的回退包裹：原图 + 每帧滤镜（模糊 + 饱和）。
  Widget wrapFallback(Widget child) {
    return ColorFiltered(
      colorFilter: saturationColorFilter(saturation),
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: blurSigma,
          sigmaY: blurSigma,
        ),
        child: child,
      ),
    );
  }

  /// 释放预烘焙纹理（与 [disposeLater] 挂起的回调可能重复释放，行为同原实现）。
  void dispose() {
    _current?.dispose();
    _old?.dispose();
  }
}
