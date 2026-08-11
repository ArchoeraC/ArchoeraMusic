import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/scheduler.dart';

import '../../services/playback/playback_notifier.dart';
import '../../stores/app_prefs.dart';
import '../common/anim.dart';

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
    // 仅样式/时间源变化时才更新并触发重绘（平时由 ticker 直接驱动绘制）
    if (_painter.barWidth != barWidth ||
        _painter.color != color ||
        _painter.nowMs != _clockMs) {
      _painter
        ..barWidth = barWidth
        ..color = color
        ..nowMs = _clockMs;
      _repaint.value++;
    }
    // 对齐原版：播放时 opacity（默认 0.65），暂停时同比例压暗
    // （原版 show ? 0.65 : 0.15，保持相同 0.15/0.65 比例缩放）
    final targetOpacity = playing ? widget.opacity : widget.opacity * (0.15 / 0.65);
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

  /// 时间源（每 tick 更新）。
  int nowMs = 0;

  /// 双声道三态缓冲：prev（上一推送帧）/ curr（当前推送帧）/ display（平滑值）。
  final List<Float64List> _prev = [
    Float64List(fftSize),
    Float64List(fftSize),
  ];
  final List<Float64List> _curr = [
    Float64List(fftSize),
    Float64List(fftSize),
  ];
  final List<Float64List> _display = [
    Float64List(fftSize),
    Float64List(fftSize),
  ];

  /// 双声道拼接缓冲（左倒序 + 右正序，2×120）。
  final Float64List _stereo = Float64List(fftSize * 2);

  int _lastUpdateMs = 0;

  /// 推入一帧新数据（ldata/rdata 为 128 bins [0,1]）。
  void pushFrame(FftFrame frame, int nowMs) {
    final l = frame.ldata;
    final r = frame.rdata;
    for (var i = 0; i < fftSize; i++) {
      _prev[0][i] = _curr[0][i];
      _prev[1][i] = _curr[1][i];
      _curr[0][i] = i < l.length ? l[i] : 0.0;
      _curr[1][i] = i < r.length ? r[i] : 0.0;
    }
    _lastUpdateMs = nowMs;
  }

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
    final t = math.min((nowMs - _lastUpdateMs) / pushIntervalMs, 1.0).clamp(0.0, 1.0);
    for (var c = 0; c < 2; c++) {
      final prev = _prev[c];
      final curr = _curr[c];
      final disp = _display[c];
      for (var i = 0; i < fftSize; i++) {
        final target = prev[i] + (curr[i] - prev[i]) * t;
        if (target > disp[i]) {
          // 上行快：向目标接近 40%
          disp[i] += (target - disp[i]) * attack;
        } else {
          // 下行慢：保留 88% + 目标 12%
          disp[i] = disp[i] * decay + target * (1 - decay);
        }
      }
    }

    // 2) 双声道镜像拼接：左倒序 + 右正序（跳过极低频），usableLen = 240
    final channelLength = fftSize - skipLow;
    for (var i = 0; i < channelLength; i++) {
      _stereo[i] = _display[0][fftSize - 1 - i];
      _stereo[channelLength + i] = _display[1][skipLow + i];
    }
    final usableLen = channelLength * 2;

    // 3) bar 布局：每根 bar 覆盖一段 bin，左右扩 1 邻居空间平滑
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
          Rect.fromLTWH(i * slotWidth, size.height - barHeight, barWidth, barHeight),
          Radius.circular(radius),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter old) =>
      old.nowMs != nowMs ||
      old.barWidth != barWidth ||
      old.radius != radius ||
      old.color != color;
}
