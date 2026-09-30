// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 模糊封面背景与水纹共用的颜色滤镜。
///
/// 背景为全屏「模糊 + 饱和 + 放大 + 压暗」；此前直接用
/// `ColorFiltered(ImageFiltered(blur(45)))` 包裹实时封面——Impeller 把 `flow`
/// 的图层光栅缓存编译掉了（仅 Skia 有），只要这一帧被渲染，全屏高斯就**每帧
/// 重算**（播放页歌词/频谱/进度持续重绘 → 每帧全屏模糊）。Windows 上这些离屏
/// 缓冲按进程内存计账（WDDM/ANGLE），于是「播放页吃内存」显著。
///
/// 现在把「cover 适配 → 放大 → 模糊 → 饱和」在**封面 / 尺寸变化时烘焙一次**
/// 成 `ui.Image`（见 [_BakedBlurLayer]），此后每帧只做一次 `RawImage` 贴图；
/// 烘焙不可用（`flutter test` 软渲染、`toImageSync` 失败）时回退实时滤镜，
/// 保证观感与行为不回退。
library;

import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../list/cover_image.dart';

/// 饱和度颜色滤镜（对齐上游 `saturate`），供水纹与模糊背景共用。
ColorFilter saturationColorFilter(double saturation) {
  final s = saturation;
  final inv = 1 - s;
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  return ColorFilter.matrix(<double>[
    inv * lr + s,
    inv * lg,
    inv * lb,
    0,
    0,
    inv * lr,
    inv * lg + s,
    inv * lb,
    0,
    0,
    inv * lr,
    inv * lg,
    inv * lb + s,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]);
}

/// 模糊背景参数（对齐上游 `.bg-blur-wrap`：`blur(45px) saturate(1.2)` +
/// `scale(1.5)` + 50% 压暗）。
const double kBlurBackgroundSigma = 45;
const double kBlurBackgroundZoom = 1.5;
const double kBlurBackgroundSaturation = 1.2;

/// 模糊封面背景（对齐上游 `.bg-blur-wrap`）。
///
/// 切歌时按上游双缓冲做法**交叉淡入**（两层叠加、`ease-in-out`），避免封面
/// 硬切换；压暗层独立叠在最上方，保证过渡期不会叠加变暗。
class BlurredCover extends StatelessWidget {
  const BlurredCover({
    super.key,
    required this.cover,
    this.duration = const Duration(milliseconds: 500),
  });

  final String cover;

  /// 交叉淡入时长（对齐上游 `transition: opacity 0.5s ease-in-out`）。
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 800.0;
        final h = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 800.0;
        return Stack(
          fit: StackFit.expand,
          children: [
            // 双缓冲交叉淡入：旧图淡出、新图淡入同时进行（每层各自烘焙一次）。
            AnimatedSwitcher(
              duration: duration,
              switchInCurve: Curves.easeInOut,
              switchOutCurve: Curves.easeInOut,
              layoutBuilder: (currentChild, previousChildren) => Stack(
                fit: StackFit.expand,
                children: [...previousChildren, ?currentChild],
              ),
              child: KeyedSubtree(
                key: ValueKey<String>(cover),
                child: _BakedBlurLayer(cover: cover, width: w, height: h),
              ),
            ),
            // 压暗层：置于交叉淡入之外，避免过渡期两层叠加导致过暗。
            ColoredBox(color: Colors.black.withValues(alpha: 0.5)),
          ],
        );
      },
    );
  }
}

/// 单层「模糊 + 饱和 + 放大」背景，封面/尺寸变化时**烘焙一次**为静态贴图。
///
/// 烘焙分辨率按物理像素长边封顶 [maxBakeSide]（模糊后放大肉眼不可辨），避免
/// 4K 全尺寸常驻数十 MB；每帧只 `drawImage` 一次，不再重算全屏高斯。
class _BakedBlurLayer extends StatefulWidget {
  const _BakedBlurLayer({
    required this.cover,
    required this.width,
    required this.height,
  });

  final String cover;
  final double width;
  final double height;

  @override
  State<_BakedBlurLayer> createState() => _BakedBlurLayerState();
}

class _BakedBlurLayerState extends State<_BakedBlurLayer> {
  /// 烘焙分辨率上限（物理像素长边）：模糊后放大肉眼不可辨；封顶避免 4K 全尺寸
  /// 常驻（3840×2160×4B ≈ 32MB/张；交叉淡入期两张）。
  static const int maxBakeSide = 2048;

  /// 测试（fake-async 软渲染）下 `Picture.toImageSync` 不可靠，直接回退实时滤镜。
  static bool get _canBake => !Platform.environment.containsKey('FLUTTER_TEST');

  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageProvider? _provider;
  int _decodePx = 0;

  /// 解码后的源图（烘焙输入）。
  ui.Image? _source;

  /// 烘焙结果；非空时按静态贴图渲染。
  ui.Image? _baked;

  /// 当前烘焙的输入指纹；变化才重烘焙。
  Object? _bakedKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final px = _targetDecodePx();
    if (_provider == null || px != _decodePx) {
      _decodePx = px;
      _resolve();
    }
  }

  @override
  void didUpdateWidget(_BakedBlurLayer old) {
    super.didUpdateWidget(old);
    if (old.cover != widget.cover) {
      _resolve();
    }
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener!);
    _baked?.dispose();
    super.dispose();
  }

  /// 解码目标长边（物理像素）：封顶 [maxBakeSide]，避免整幅解码后又大图烘焙。
  int _targetDecodePx() {
    final mq = MediaQuery.maybeOf(context);
    if (mq == null) return maxBakeSide;
    final s = mq.size;
    final longest = (s.width > s.height ? s.width : s.height) * mq.devicePixelRatio;
    return longest.round().clamp(256, maxBakeSide);
  }

  void _resolve() {
    _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
    _source = null;
    _bakedKey = null;
    _disposeLater(_baked);
    _baked = null;
    final provider = coverImageProvider(widget.cover, decodeWidth: _decodePx);
    _provider = provider;
    if (provider == null) return; // 无封面：回退实时滤镜（CoverImage 空图）
    final listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      setState(() {
        _source = info.image;
        _bakedKey = null;
      });
    }, onError: (_, _) {});
    _listener = listener;
    _stream = provider.resolve(ImageConfiguration.empty)..addListener(listener);
  }

  /// 延后一帧释放，避免当前帧仍被绘制引用。
  void _disposeLater(ui.Image? img) {
    if (img == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => img.dispose());
  }

  /// 输入指纹变化时排一次烘焙（post-frame，避免在 build 中做 GPU 工作）。
  void _scheduleBake(ui.Image source, Size size, double dpr) {
    final key = Object.hash(
      identityHashCode(source),
      size.width,
      size.height,
      dpr,
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

  /// 同步烘焙：cover 适配 → 放大 1.5（绕中心）→ 高斯模糊 → 饱和，输出物理像素。
  ui.Image? _bake(ui.Image source, Size size, double dpr) {
    final physicalLongest = math.max(size.width, size.height) * dpr;
    final bakeScale = physicalLongest > maxBakeSide
        ? maxBakeSide / physicalLongest
        : 1.0;
    final w = (size.width * dpr * bakeScale).round().clamp(1, maxBakeSide);
    final h = (size.height * dpr * bakeScale).round().clamp(1, maxBakeSide);
    final out = Size(w.toDouble(), h.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & out);

    final paint = Paint()
      ..filterQuality = FilterQuality.low
      // 逻辑 σ=45 → 物理像素；烘焙若降采样，σ 同比缩小（放大回屏后等效不变）。
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: kBlurBackgroundSigma * dpr * bakeScale,
        sigmaY: kBlurBackgroundSigma * dpr * bakeScale,
        tileMode: TileMode.clamp,
      )
      ..colorFilter = saturationColorFilter(kBlurBackgroundSaturation);

    final srcSize = Size(source.width.toDouble(), source.height.toDouble());
    final fitted = applyBoxFit(BoxFit.cover, srcSize, out);
    final srcRect = Alignment.center.inscribe(fitted.source, Offset.zero & srcSize);
    final dstRect = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & out,
    );

    canvas.save();
    // 放大（对齐上游 Transform.scale(1.5)）：绕中心缩放后再 cover 铺满。
    if (kBlurBackgroundZoom != 1) {
      canvas
        ..translate(out.width / 2, out.height / 2)
        ..scale(kBlurBackgroundZoom)
        ..translate(-out.width / 2, -out.height / 2);
    }
    canvas.drawImageRect(source, srcRect, dstRect, paint);
    canvas.restore();

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
    final size = Size(widget.width, widget.height);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final source = _source;
    if (_canBake && source != null) {
      _scheduleBake(source, size, dpr);
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
    // 烘焙未就绪 / 不可用（测试）时的实时滤镜回退（与烘焙前观感一致）。
    return _live(size);
  }

  /// 实时滤镜回退：单层模糊封面（模糊 + 饱和 + 放大）。
  Widget _live(Size size) {
    return ColorFiltered(
      colorFilter: saturationColorFilter(kBlurBackgroundSaturation),
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: kBlurBackgroundSigma,
          sigmaY: kBlurBackgroundSigma,
          tileMode: TileMode.clamp,
        ),
        child: Transform.scale(
          scale: kBlurBackgroundZoom,
          child: CoverImage(
            cover: widget.cover,
            width: size.width,
            height: size.height,
            radius: 0,
            iconSize: 0,
          ),
        ),
      ),
    );
  }
}
