import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/scheduler.dart';

import '../../services/playback/playback_notifier.dart';
import '../../stores/app_prefs.dart';
import '../common/anim.dart';

/// 频谱可视化样式（独立渲染效果，复用同一 FFT 数据缓冲，资源开销等同）。
enum SpectrumStyle {
  /// 经典条形：双声道镜像、底部对齐、圆角柱（原版默认）。
  bars,

  /// 波形线：镜像对称的频谱包络曲线，形似声波。
  wave,

  /// 单向上波形：包络曲线只向基线一侧（上）延伸，无镜像。
  waveUp;

  /// 偏好存储值（player.spectrumStyle）。
  String get storageKey => name;

  /// 从偏好字符串解析（非法值回退 bars）。
  static SpectrumStyle fromStorage(String? value) =>
      SpectrumStyle.values.firstWhere(
        (e) => e.name == value,
        orElse: () => SpectrumStyle.bars,
      );
}

/// 频谱可视化（复刻 Web 端 BottomSpectrum.vue，架构文档 §10.1）。
///
/// 链路：引擎直写 stream.pcm → PcmAnalyzer 按播放位置拉块 → FFI FFT →
/// PlaybackState.fft（128 bins [0,1]）→ 此处插值渲染。
///
/// 渲染语义（与 Vue 版逐项对齐）：
///  - 帧间时间插值（50ms 推送 → ~16ms 重绘，消除 20Hz 阶梯）
///  - 上行快 / 下行慢（ATTACK 0.4 / DECAY 0.88）
///  - 双声道拼接：左声道倒序 + 右声道正序（SKIP_LOW 起，镜像对称）
///  - 每个 bar 覆盖一段 bin 并左右各扩 1 邻居做空间平滑
///  - bar 圆角 + 底部对齐
class SpectrumView extends ConsumerStatefulWidget {
  const SpectrumView({
    super.key,
    this.height = 80,
    this.barWidth,
    this.radius = 2,
    this.color,
    this.opacity = 0.65,
    this.enabled,
    this.style,
  });

  /// 画布高度（逻辑像素）。
  final double height;

  /// 单根 bar 宽度（px）；null 时跟随设置（player.spectrumBarWidth）。
  final double? barWidth;

  /// bar 圆角（px）。
  final double radius;

  /// bar 颜色；默认跟随主题 primary。
  final Color? color;

  /// 整体不透明度（对齐原版 BottomSpectrum：播放器内 0.65 / 迷你条 0.15，
  /// 300ms 过渡）。
  final double opacity;

  /// 独立启用开关（null = 跟随全局「频谱」设置；播放条迷你频谱传
  /// `player.barSpectrum` 与该全局开关解耦）。
  final bool? enabled;

  /// 频谱样式；null 时跟随设置（player.spectrumStyle）。
  final SpectrumStyle? style;

  @override
  ConsumerState<SpectrumView> createState() => _SpectrumViewState();
}

class _SpectrumViewState extends ConsumerState<SpectrumView>
    with SingleTickerProviderStateMixin {
  /// 匀速时钟（累计 elapsed，提供 paint 插值时间源）。
  late final Ticker _ticker;
  int _clockMs = 0;

  /// 仅触发绘制、不重建不重布局的 repaint 通知（60fps 节能关键：
  /// setState 会连带重建/重排整棵子树，这里只让 CustomPaint 重绘）。
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);

  late final _SpectrumPainter _painter;

  /// 已推送的最新帧引用（identity 比对，避免重复推帧）。
  FftFrame? _lastPushed;

  @override
  void initState() {
    super.initState();
    _painter = _SpectrumPainter(
      barWidth: 4,
      radius: widget.radius,
      repaint: _repaint,
    );
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _repaint.dispose();
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    _clockMs += elapsed.inMilliseconds;
    _painter.nowMs = _clockMs;
    _repaint.value++; // 触发 CustomPaint 重绘（免 setState/重建/重布局）
  }

  @override
  Widget build(BuildContext context) {
    // 仅订阅 FFT 帧与播放态：位置等高频更新不再触发本组件重建
    final fft = ref.watch(playbackProvider.select((s) => s.fft));
    final playing = ref.watch(playbackProvider.select((s) => s.playing));
    final prefs = ref.watch(appPrefsProvider);

    // 频谱关闭（或性能模式自动关闭）：不渲染（空占位保持布局稳定），
    // 同时停掉 60fps ticker 重绘省电——性能模式下与关闭频谱完全等价。
    // enabled 非 null 时优先（播放条迷你频谱独立于全局开关）。
    final enabled =
        (widget.enabled ?? prefs.enableSpectrum) && !prefs.performanceMode;
    if (!enabled) {
      _ticker.muted = true;
      return SizedBox(width: double.infinity, height: widget.height);
    }

    final barWidth = widget.barWidth ?? prefs.spectrumBarWidth.toDouble();
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    final style = widget.style ?? SpectrumStyle.fromStorage(prefs.spectrumStyle);
    // 仅样式/时间源变化时才更新并触发重绘（平时由 ticker 直接驱动绘制）
    if (_painter.barWidth != barWidth ||
        _painter.color != color ||
        _painter.style != style ||
        _painter.nowMs != _clockMs) {
      _painter
        ..barWidth = barWidth
        ..color = color
        ..style = style
        ..nowMs = _clockMs;
      _repaint.value++;
    }
    // 对齐原版：播放时 opacity（默认 0.65），暂停时同比例压暗
    // （原版 show ? 0.65 : 0.15，保持相同 0.15/0.65 比例缩放）
    final targetOpacity = playing
        ? widget.opacity
        : widget.opacity * (0.15 / 0.65);
    // 暂停节能：停止 ticker 重绘（对齐原版暂停停止 RAF）
    _ticker.muted = !playing;

    if (fft == null) {
      // 停止/未加载：清空插值缓冲区，频谱归零
      if (_lastPushed != null) {
        _lastPushed = null;
        _painter.reset();
        _repaint.value++;
      }
    } else if (!identical(_lastPushed, fft)) {
      _lastPushed = fft;
      _painter.pushFrame(fft, _clockMs);
      _repaint.value++;
    }

    // 两侧渐隐（对齐原版 CSS mask：0/5/12/88/95/100% 不透明梯度）
    // RepaintBoundary：隔离 60fps 重绘，避免污染播放页其余区域
    return RepaintBoundary(
      child: AnimatedOpacity(
        opacity: targetOpacity,
        duration: animDuration(context, const Duration(milliseconds: 300)),
        curve: Curves.easeOut,
        child: ShaderMask(
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Color(0x00000000),
              Color(0x99FFFFFF), // 60% 白
              Color(0xFFFFFFFF),
              Color(0xFFFFFFFF),
              Color(0x99FFFFFF),
              Color(0x00000000),
            ],
            stops: [0.0, 0.05, 0.12, 0.88, 0.95, 1.0],
          ).createShader(rect),
          blendMode: BlendMode.dstIn,
          child: CustomPaint(
            size: Size(double.infinity, widget.height),
            painter: _painter,
          ),
        ),
      ),
    );
  }
}

/// 频谱绘制器：持有 prev/curr/display 三套缓冲区，实现插值 + 指数平滑。
class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter({
    required this.barWidth,
    required this.radius,
    super.repaint,
  });

  /// 对齐 Web：后端推送 128 bins / 50ms。
  static const int fftSize = 128;
  static const int pushIntervalMs = 50;

  /// 极低频跳过段数（噪声多，对齐 Web SKIP_LOW=8）。
  static const int skipLow = 8;

  /// bar 间隙（px，对齐 Web BAR_GAP=3）。
  static const int barGap = 3;

  /// 上行快 / 下行慢（对齐 Web）。
  static const double attack = 0.4;
  static const double decay = 0.88;

  /// 归一化 [0,1] 数据低于该高度阈值时跳过绘制（避免 0.5px 以下毛刺）。
  static const double _minBarHeight = 0.5;

  double barWidth;
  double radius;
  Color color = Colors.transparent;
  SpectrumStyle style = SpectrumStyle.bars;

  /// 时间源（每 tick 更新）。
  int nowMs = 0;

  /// 双声道三态缓冲：prev（上一推送帧）/ curr（当前推送帧）/ display（平滑值）。
  final List<Float64List> _prev = [Float64List(fftSize), Float64List(fftSize)];
  final List<Float64List> _curr = [Float64List(fftSize), Float64List(fftSize)];
  final List<Float64List> _display = [
    Float64List(fftSize),
    Float64List(fftSize),
  ];

  /// 双声道拼接缓冲（左倒序 + 右正序，2×120）。
  final Float64List _stereo = Float64List(fftSize * 2);

  int _lastUpdateMs = 0;

  /// 推入一帧新数据（ldata/rdata 为 128 bins [0,1]）。
  ///
  /// 降帧协商：对非法样本（NaN/Inf/负值，FFT 异常帧可能产生）按 0
  /// 归一化，防止污染 _display 缓冲后逐帧扩散导致绘制崩溃。
  void pushFrame(FftFrame frame, int nowMs) {
    final l = frame.ldata;
    final r = frame.rdata;
    for (var i = 0; i < fftSize; i++) {
      _prev[0][i] = _curr[0][i];
      _prev[1][i] = _curr[1][i];
      _curr[0][i] = i < l.length ? _finite(l[i]) : 0.0;
      _curr[1][i] = i < r.length ? _finite(r[i]) : 0.0;
    }
    _lastUpdateMs = nowMs;
  }

  /// 非法样本归一化（NaN/Inf/负值 → 0）。
  static double _finite(double v) => v.isFinite && v >= 0 ? v : 0.0;

  /// 清空全部缓冲（停止播放时调用）。
  void reset() {
    for (final b in _prev) {
      b.fillRange(0, fftSize, 0);
    }
    for (final b in _curr) {
      b.fillRange(0, fftSize, 0);
    }
    for (final b in _display) {
      b.fillRange(0, fftSize, 0);
    }
    _stereo.fillRange(0, _stereo.length, 0);
    _lastUpdateMs = nowMs;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 1) 帧间时间插值：在 prev→curr 间按推送进度线性过渡，消除 20Hz 阶梯
    final t = math
        .min((nowMs - _lastUpdateMs) / pushIntervalMs, 1.0)
        .clamp(0.0, 1.0);
    for (var c = 0; c < 2; c++) {
      final prev = _prev[c];
      final curr = _curr[c];
      final disp = _display[c];
      for (var i = 0; i < fftSize; i++) {
        final target = _finite(prev[i] + (curr[i] - prev[i]) * t);
        if (target > disp[i]) {
          // 上行快：向目标接近 40%
          disp[i] += (target - disp[i]) * attack;
        } else {
          // 下行慢：保留 88% + 目标 12%
          disp[i] = disp[i] * decay + target * (1 - decay);
        }
      }
    }

    // 2) 双声道镜像拼接（各样式共用数据缓冲）：左倒序 + 右正序，
    //    跳过极低频，usableLen = 240
    final usableLen = _buildBins();
    if (usableLen <= 0) return;

    // 3) 按所选样式渲染（独立效果，复用同一缓冲，开销等同）
    switch (style) {
      case SpectrumStyle.bars:
        _paintBars(canvas, size, usableLen);
      case SpectrumStyle.wave:
        _paintWave(canvas, size, usableLen, mirror: true);
      case SpectrumStyle.waveUp:
        _paintWave(canvas, size, usableLen, mirror: false);
    }
  }

  /// 双声道镜像拼接：usableLen = (fftSize - skipLow) * 2。
  int _buildBins() {
    final channelLength = fftSize - skipLow;
    for (var i = 0; i < channelLength; i++) {
      _stereo[i] = _display[0][fftSize - 1 - i];
      _stereo[channelLength + i] = _display[1][skipLow + i];
    }
    return channelLength * 2;
  }

  /// 经典条形：每根 bar 覆盖一段 bin，左右扩 1 邻居空间平滑，底部对齐。
  void _paintBars(Canvas canvas, Size size, int usableLen) {
    final slotWidth = barWidth + barGap;
    final numBars = (size.width / slotWidth).floor();
    if (numBars <= 0) return;

    final paint = Paint()..color = color;
    for (var i = 0; i < numBars; i++) {
      final startBin = (i * usableLen / numBars).floor();
      final endBin = ((i + 1) * usableLen / numBars).floor();
      final lo = math.max(0, startBin - 1);
      final hi = math.min(usableLen, math.max(endBin, startBin + 1) + 1);
      var sum = 0.0;
      for (var j = lo; j < hi; j++) {
        sum += _stereo[j];
      }
      final v = sum / (hi - lo);

      final barHeight = v * size.height;
      if (barHeight <= _minBarHeight) continue;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            i * slotWidth,
            size.height - barHeight,
            barWidth,
            barHeight,
          ),
          Radius.circular(radius),
        ),
        paint,
      );
    }
  }

  /// 波形线：频谱包络曲线。mirror=true 上下镜像（wave）；false 只向基线
  /// 一侧（上）延伸（waveUp）。渲染细节：
  ///  - 3 点滑动平均平滑包络，抑制单 bin 毛刺
  ///  - 二次贝塞尔以「相邻采样点中点」为终点、当前点为控制点，曲线圆滑
  ///    经过采样包络，消除折线棱角
  void _paintWave(
    Canvas canvas,
    Size size,
    int usableLen, {
    required bool mirror,
  }) {
    if (usableLen <= 1 || size.width <= 0) return;
    final midY = size.height / 2;
    final amp = math.max(size.height / 2 - 2, 1.0);

    // 左右安全边距：波形线横贯整宽，若曲线贴边（x=0 / x=width），其端部
    // 会被外层圆角遮罩裁切出线头「亮点」（迷你播放条为 30px 圆角）。
    // 曲线端部应收束在遮罩圆角之外——由曲线自身留边距解决，而非加宽
    // 遮罩兜底。全屏页无遮罩时亦保留统一内边距。
    final pad = math.min(16.0, size.width * 0.05);
    final curveWidth = size.width - 2 * pad;
    if (curveWidth <= 2) return;
    final stepX = curveWidth / (usableLen - 1);

    // 3 点滑动平均（含边界收缩窗口），clamp 到 [0,1]
    final smoothBins = Float64List(usableLen);
    for (var i = 0; i < usableLen; i++) {
      final lo = math.max(0, i - 1);
      final hi = math.min(usableLen - 1, i + 1);
      var sum = 0.0;
      var n = 0;
      for (var j = lo; j <= hi; j++) {
        final raw = _stereo[j];
        sum += raw < 0 ? 0.0 : (raw > 1 ? 1.0 : raw);
        n++;
      }
      smoothBins[i] = sum / n;
    }

    // 边缘淡出：FFT 两端（最高频段）常有噪声 spike，未衰减时曲线从高位
    // 出发，首段贝塞尔会在端部形成陡峭短竖线 + 圆帽，视觉突兀。
    // 首尾 fadeLen 个 bin 线性衰减至基线（0），配合安全边距让曲线两端
    // 在遮罩外平滑收束，无突兀线头。
    const fadeLen = 12;
    for (var i = 0; i < fadeLen && i < usableLen; i++) {
      final k = i / fadeLen;
      smoothBins[i] *= k;
      final j = usableLen - 1 - i;
      if (j > i) {
        smoothBins[j] *= k;
      }
    }

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, math.min(3.0, barWidth))
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // sign=±1 决定曲线位于基线上方/下方
    void trace(Path path, double sign) {
      path.moveTo(pad, midY + sign * smoothBins[0] * amp);
      for (var i = 0; i < usableLen - 1; i++) {
        final y = midY + sign * smoothBins[i] * amp;
        final yMid =
            midY + sign * ((smoothBins[i] + smoothBins[i + 1]) / 2) * amp;
        path.quadraticBezierTo(
          pad + i * stepX,
          y,
          pad + (i + 0.5) * stepX,
          yMid,
        );
      }
      path.lineTo(
        pad + (usableLen - 1) * stepX,
        midY + sign * smoothBins[usableLen - 1] * amp,
      );
    }

    final upper = Path();
    trace(upper, -1);
    canvas.drawPath(upper, paint);
    if (mirror) {
      final lower = Path();
      trace(lower, 1);
      canvas.drawPath(lower, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter old) =>
      old.nowMs != nowMs ||
      old.barWidth != barWidth ||
      old.radius != radius ||
      old.color != color ||
      old.style != style;
}
