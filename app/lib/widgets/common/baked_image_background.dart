// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 静态图片背景的**一次性烘焙**（Electron 式静态层）。
///
/// Impeller 把 `flow` 的图层光栅缓存编译掉了（仅 Skia 有），因此实时
/// `ImageFiltered` 的高斯模糊会在**每一帧**重算——只要这一帧被渲染，全屏
/// 模糊就重来一遍（见 docs/runtime-resource-optimization.md §3.6/§4.2）。
///
/// 本组件把「cover 适配 → 缩放 → 高斯模糊 → 压暗」在**图片 / 尺寸 / 参数
/// 变化时烘焙一次**成 `ui.Image`，此后每帧只做一次 `RawImage` 贴图；烘焙
/// 不可用（`flutter test` 软渲染、`toImageSync` 失败）时回退实时滤镜，
/// 保证观感与行为不回退。
library;

import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// 把 [provider] 解码后按 [scale] 缩放、按 [blurSigma] 模糊、叠 [dim] 压暗，
/// 烘焙成一张静态背景纹理。
class BakedImageBackground extends StatefulWidget {
  const BakedImageBackground({
    super.key,
    required this.provider,
    required this.blurSigma,
    required this.scale,
    required this.dim,
  });

  /// 背景图（调用方负责按显示尺寸解码，如 [ResizeImage]）。
  final ImageProvider provider;

  /// 高斯模糊半径（逻辑像素；0 = 不模糊）。
  final double blurSigma;

  /// 缩放倍率（1 = 原始；对齐 `backgroundScale`）。
  final double scale;

  /// 压暗强度（0~1，黑色叠加 alpha）。
  final double dim;

  @override
  State<BakedImageBackground> createState() => _BakedImageBackgroundState();
}

class _BakedImageBackgroundState extends State<BakedImageBackground> {
  /// 测试（fake-async 软渲染）下 `Picture.toImageSync` 不可靠，直接回退实时滤镜。
  static bool get _canBake => !Platform.environment.containsKey('FLUTTER_TEST');

  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// 解码后的源图（烘焙输入）。
  ui.Image? _source;

  /// 烘焙结果；非空时按静态贴图渲染。
  ui.Image? _baked;

  /// 当前烘焙的输入指纹；与 [_scheduleBake] 计算值不同才重烘焙。
  Object? _bakedKey;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(BakedImageBackground old) {
    super.didUpdateWidget(old);
    if (old.provider != widget.provider) {
      _resolve();
      return;
    }
    if (old.blurSigma != widget.blurSigma ||
        old.scale != widget.scale ||
        old.dim != widget.dim) {
      _bakedKey = null; // 参数变化 → 下一帧重烘焙
    }
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener!);
    _baked?.dispose();
    super.dispose();
  }

  void _resolve() {
    _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
    _source = null;
    _bakedKey = null;
    _disposeLater(_baked);
    _baked = null;
    final listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      _source = info.image;
      _bakedKey = null;
      setState(() {});
    }, onError: (_, _) {});
    _listener = listener;
    _stream = widget.provider.resolve(ImageConfiguration.empty)
      ..addListener(listener);
  }

  void _disposeLater(ui.Image? img) {
    if (img == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => img.dispose());
  }

  /// 输入指纹变化时排一次烘焙（post-frame，避免在 build 中做 GPU 工作）。
  void _scheduleBake(ui.Image source, Size size) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final key = Object.hash(
      identityHashCode(source),
      size.width,
      size.height,
      dpr,
      widget.blurSigma,
      widget.scale,
      widget.dim,
    );
    if (key == _bakedKey) return;
    _bakedKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final baked = _bake(source, size, dpr);
      if (baked == null) return;
      final old = _baked;
      setState(() => _baked = baked);
      _disposeLater(old);
    });
  }

  /// 同步烘焙：cover 适配 → 缩放（绕中心）→ 模糊 → 压暗，输出物理像素尺寸。
  ui.Image? _bake(ui.Image source, Size size, double dpr) {
    final w = (size.width * dpr).round().clamp(1, 8192);
    final h = (size.height * dpr).round().clamp(1, 8192);
    final out = Size(w.toDouble(), h.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & out);

    final paint = Paint()..filterQuality = FilterQuality.low;
    if (widget.blurSigma > 0) {
      paint.imageFilter = ui.ImageFilter.blur(
        sigmaX: widget.blurSigma * dpr,
        sigmaY: widget.blurSigma * dpr,
        tileMode: TileMode.clamp,
      );
    }
    final srcSize = Size(source.width.toDouble(), source.height.toDouble());
    final fitted = applyBoxFit(BoxFit.cover, srcSize, out);
    final srcRect = Alignment.center.inscribe(
      fitted.source,
      Offset.zero & srcSize,
    );
    final dstRect = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & out,
    );
    canvas.save();
    if (widget.scale != 1) {
      canvas
        ..translate(out.width / 2, out.height / 2)
        ..scale(widget.scale)
        ..translate(-out.width / 2, -out.height / 2);
    }
    canvas.drawImageRect(source, srcRect, dstRect, paint);
    canvas.restore();
    if (widget.dim > 0) {
      canvas.drawRect(
        Offset.zero & out,
        Paint()..color = Colors.black.withValues(alpha: widget.dim),
      );
    }

    final pic = recorder.endRecording();
    try {
      return pic.toImageSync(w, h);
    } catch (_) {
      return null;
    } finally {
      pic.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(
          constraints.maxWidth.isFinite ? constraints.maxWidth : 800,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 800,
        );
        final source = _source;
        if (_canBake && source != null) {
          _scheduleBake(source, size);
          final baked = _baked;
          if (baked != null) {
            return RawImage(
              image: baked,
              width: size.width,
              height: size.height,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.low,
            );
          }
        }
        return _live(size);
      },
    );
  }

  /// 烘焙未就绪 / 不可用时的实时滤镜回退（与烘焙前观感一致）。
  Widget _live(Size size) {
    Widget image = Image(
      image: widget.provider,
      width: size.width,
      height: size.height,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
    if (widget.blurSigma > 0) {
      image = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: widget.blurSigma,
          sigmaY: widget.blurSigma,
          tileMode: TileMode.clamp,
        ),
        child: image,
      );
    }
    if (widget.scale != 1) {
      image = Transform.scale(scale: widget.scale, child: image);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        image,
        ColoredBox(color: Colors.black.withValues(alpha: widget.dim)),
      ],
    );
  }
}
