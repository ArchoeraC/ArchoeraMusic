// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../lyrics_physics_wall.dart';

/// 单行烘焙结果：1/4 逻辑分辨率的失焦外观 + 相对行中心 `cy` 的纵向范围。
class _BakedLine {
  const _BakedLine({
    required this.image,
    required this.top,
    required this.bottom,
  });

  final ui.Image image;

  /// 相对行中心 `cy` 的上下边界（逻辑像素，已含内容 pad 与模糊余量）。
  final double top;
  final double bottom;
}

/// 整层档（panel）稳态「静态层逐行烘焙」（渲染专项 D2a）。
///
/// 思路参考外部合成器渲染调研的「显式栅格化」纪律——Impeller GLES 下
/// raster cache 关闭，指望框架缓存不可靠，需要缓存的层必须自己栅格成
/// [ui.Image]（见 `docs/rendering-reference-research.md` D4，自研实现）。
///
/// 稳态（无弹簧运动 / 无过渡 / 无悬停动画）时，非激活行的外观——含整层
/// 1/4 重采样的失焦高斯——完全不变。此时把每行烘焙成 1/4 逻辑分辨率的
/// 小图：每帧只逐行贴图 + 重绘激活行，**每帧的整层高斯 saveLayer（物理
/// 分辨率离屏 target）与全部非激活行段落重放一并消失**。
///
/// **缓存与位置无关（2026-11-03 修正）**：烘焙内容只取决于行内容与样式，
/// 与行在屏幕上的 y / 激活行 / 淡入权重无关——这些都在**绘制时**应用
/// （y 决定贴图目标矩形、透明度决定贴图着色）。因此换行/滚动**不会**使
/// 缓存失效：每次换行只对新进入视口的行烘一张（~1 张），而不是把可见的
/// 十几行全部重烘（那会在换行后首帧造成一次明显尖峰）。
///
/// 烘焙管线刻意与现行逐行高斯**逐像素同源**（保观感是硬要求）：
/// 1. 行内容按**物理分辨率**栅格（与离屏 target 的栅格分辨率一致）；
/// 2. 双线性降采样到 1/4 逻辑网格；
/// 3. 在 1/4 网格上 blur(σ·k)；
/// 4. 每帧 drawImageRect 双线性放大（= 逐行高斯后的等效尺寸）。
/// 单行的全分辨率中间图随建随弃，峰值内存 = 单行区域（数 MB 级）。
///
/// 行间模糊渗色：行中心间距 ≫ 3σ（σ ≤ [kPanelBlurPx] → 渗色 ≤ 12 逻辑 px，
/// 行距 ≥ ~130px），逐行烘焙与整层烘焙在行间不产生可辨差异。
///
/// 内存（常驻）：Σ 可见行区域 × k² × 4B ≈ 全视口的 1/16 —— 1080p ≈ 0.5MB、
/// 4K ≈ 2MB，O(视口) 且与歌长无关（§3.4 内存纪律）。
class _WallBake {
  final Map<int, _BakedLine> _lines = <int, _BakedLine>{};
  final Set<int> _failed = <int>{};
  Object? _styleKey;

  /// 累计烘焙行数（诊断/测试：换行不应使其大幅增长）。
  int bakedCount = 0;

  /// 当前缓存的烘焙图数量（诊断/测试）。
  int get cachedCount => _lines.length;

  /// 内容/样式键：**不含** y、激活行、淡入权重、可见集合。
  Object _keyOf(_PaintCtx c) => (
    groups: identityHashCode(c.groups),
    w: c.w,
    fontSize: c.fontSize,
    fontFamily: c.fontFamily,
    weight: c.fontWeight.value,
    played: c.played.toARGB32(),
    unplayed: c.unplayed.toARGB32(),
    inactiveAlpha: c.inactiveAlpha,
    textAlign: c.textAlign,
    showTranslation: c.showTranslation,
    showRomanization: c.showRomanization,
    sigma: kPanelBlurSigma * c.blurStrength.clamp(0.0, 1.0),
    scale: c.enableScale ? 0.97 : 1.0,
    dpr: c.dpr,
  );

  /// 取某行的烘焙图（**只查不烘**）。
  ///
  /// 缺失时返回 null，调用方回退逐行高斯（观感等价）并交给
  /// [prefetchOne] 在后续稳态帧分摊烘焙——避免「新行进入视口的那一帧」
  /// 当场烘焙（3 次 toImageSync 与光栅线程串行，会造成换行帧的卡顿尖峰）。
  _BakedLine? lookup(_PaintCtx c, int index) {
    _ensureKey(c);
    return _lines[index];
  }

  /// 稳态帧预取：为可见范围附近尚未烘焙的行烘**一张**（每帧最多一张）。
  ///
  /// 稳态帧只有贴图 + 激活行，留有余量；提前把即将进入视口的行烘好，
  /// 换行/滚动时就不会再触发烘焙。返回是否真的烘了一张。
  bool prefetchOne(_Painter painter, _PaintCtx c, Set<int> visible) {
    if (visible.isEmpty) return false;
    _ensureKey(c);
    final n = c.groups.length;
    var minV = n;
    var maxV = -1;
    for (final i in visible) {
      if (i < minV) minV = i;
      if (i > maxV) maxV = i;
    }
    // 视口上下各预取 2 行（覆盖一次级联换行带来的新进入行）。
    final from = math.max(0, minV - 2);
    final to = math.min(n - 1, maxV + 2);
    for (var i = from; i <= to; i++) {
      if (_lines.containsKey(i) || _failed.contains(i)) continue;
      final baked = _bakeLine(painter, c, i);
      if (baked != null) {
        _lines[i] = baked;
        bakedCount += 1;
      } else {
        // 烘焙失败（纹理超限等）：本样式周期内不再重试，回退逐行高斯。
        _failed.add(i);
      }
      return true;
    }
    return false;
  }

  void _ensureKey(_PaintCtx c) {
    final key = _keyOf(c);
    if (key == _styleKey) return;
    _styleKey = key;
    _clear();
    _failed.clear();
  }

  _BakedLine? _bakeLine(_Painter painter, _PaintCtx c, int index) {
    const k = kPanelBlurDownsample;
    final sigma = kPanelBlurSigma * c.blurStrength.clamp(0.0, 1.0);
    // 行 bounds 与位置无关（以 cy = 0 计算），再扩「内容 pad + 3σ」余量。
    final base = painter._lineBounds(index, 0.0);
    final margin = c.fontSize * 0.5 + 3 * sigma;
    final top = base.top - margin;
    final bottom = base.bottom + margin;
    final height = bottom - top;
    if (height <= 0 || c.w <= 0) return null;

    // 物理分辨率上限保护（极端超宽视口时降低内容栅格精度，不崩）。
    final dpr = math.min(c.dpr, 8192 / math.max(1.0, c.w));
    final wPx = math.max(1, (c.w * dpr).round());
    final hPx = math.max(1, (height * dpr).round());
    final kw = math.max(1, (c.w * k).round());
    final kh = math.max(1, (height * k).round());
    final scale = c.enableScale ? 0.97 : 1.0;

    try {
      // 1) 行内容（物理分辨率；透明度按 1.0 烘焙，绘制时再乘实际 alpha——
      //    高斯对 alpha 是线性的，因此与「按实际 alpha 烘焙」等价）。
      final rec1 = ui.PictureRecorder();
      final cv1 = ui.Canvas(
        rec1,
        Rect.fromLTWH(0, 0, wPx.toDouble(), hPx.toDouble()),
      );
      cv1.scale(dpr);
      cv1.translate(0, -top);
      painter._drawBase(
        cv1,
        index,
        0.0,
        0.0,
        alphaOverride: 1.0,
        scaleOverride: scale,
      );
      final content = rec1.endRecording();
      final img1 = content.toImageSync(wPx, hPx);
      content.dispose();

      // 2) 双线性降采样到 1/4 逻辑网格。
      final rec2 = ui.PictureRecorder();
      final cv2 = ui.Canvas(
        rec2,
        Rect.fromLTWH(0, 0, kw.toDouble(), kh.toDouble()),
      );
      cv2.drawImageRect(
        img1,
        Rect.fromLTWH(0, 0, wPx.toDouble(), hPx.toDouble()),
        Rect.fromLTWH(0, 0, kw.toDouble(), kh.toDouble()),
        Paint()..filterQuality = ui.FilterQuality.low,
      );
      final imgDown = rec2.endRecording().toImageSync(kw, kh);
      img1.dispose();

      // 3) 在 1/4 网格上 blur(σ·k)。
      final rec3 = ui.PictureRecorder();
      final cv3 = ui.Canvas(
        rec3,
        Rect.fromLTWH(0, 0, kw.toDouble(), kh.toDouble()),
      );
      cv3.saveLayer(
        Rect.fromLTWH(0, 0, kw.toDouble(), kh.toDouble()),
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: sigma * k,
            sigmaY: sigma * k,
          ),
      );
      cv3.drawImage(imgDown, Offset.zero, Paint());
      cv3.restore();
      final baked = rec3.endRecording().toImageSync(kw, kh);
      imgDown.dispose();

      return _BakedLine(image: baked, top: top, bottom: bottom);
    } on Object {
      // 烘焙失败（如纹理超限/软渲染限制）：返回 null，调用方回退逐行高斯。
      return null;
    }
  }

  /// 只保留可见行及其上下各 2 行的烘焙图（常驻内存 O(视口)，与歌长无关）。
  void pruneTo(Set<int> visible) {
    if (_lines.isEmpty) return;
    if (visible.isEmpty) {
      _clear();
      return;
    }
    var minV = 1 << 30;
    var maxV = -1;
    for (final i in visible) {
      if (i < minV) minV = i;
      if (i > maxV) maxV = i;
    }
    final from = math.max(0, minV - 2);
    final to = maxV + 2;
    _lines.removeWhere((index, baked) {
      if (index >= from && index <= to) return false;
      baked.image.dispose();
      return true;
    });
  }

  void _clear() {
    for (final baked in _lines.values) {
      baked.image.dispose();
    }
    _lines.clear();
  }

  /// 释放全部烘焙图。
  void dispose() {
    _clear();
    _styleKey = null;
  }
}
