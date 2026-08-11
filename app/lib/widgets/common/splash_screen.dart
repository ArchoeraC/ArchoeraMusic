import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../layout/app_logo.dart';

/// 启动动画（品牌 Splash）。
///
/// 动效：
/// - Logo（[AppLogo]）：**弹出式**——淡入 + 上滑 + `easeOutBack` 放大过冲；
/// - 品牌名：**文字上下特效**——逐字从下方浮现（错开节奏），
///   显示后整行缓慢上下浮动（呼吸）；
/// - 副标语延迟上滑渐显；3 颗脉冲加载圆点（loading 指示）。
/// 背景为深色氛围 + 主色径向光晕（静态）。由外层 [SplashGate] 控制淡出；
/// 引擎加载期的静态覆盖见 `linux/runner/my_application.cc`。
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  /// 加载圆点脉冲（1.05s 循环）。
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1050),
  );

  /// 入场编排（1s：Logo 弹出 + 文字逐字浮现）。
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  /// 品牌名浮动（入场后整行缓慢上下浮动）。
  late final AnimationController _float = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  /// 动画是否已启动（build 中一次性启动）。
  ///
  /// 性能模式判断（MediaQuery.maybeDisableAnimationsOf）属于依赖查询，
  /// initState 阶段不允许建立 InheritedWidget 依赖，移到 build 中执行。
  bool _animStarted = false;

  /// 启动入场动画：性能模式（disableAnimations）停掉全部动画控制器，
  /// 入场直接跳到终值态——Splash 呈现为静态画面（省 CPU/电量）。
  void _startAnimations() {
    if (_animStarted) return;
    _animStarted = true;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _intro.value = 1;
    } else {
      _pulse.repeat();
      _intro.forward();
      _float.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _intro.dispose();
    _float.dispose();
    super.dispose();
  }

  /// Logo：弹出式动效（淡入 + 上滑 + easeOutBack 放大过冲）。
  Widget _buildLogo() {
    return FadeTransition(
      opacity: Tween<double>(begin: 0, end: 1).animate(
        CurvedAnimation(
          parent: _intro,
          curve: const Interval(0, 0.4, curve: Curves.easeOut),
        ),
      ),
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.18), end: Offset.zero)
            .animate(
              CurvedAnimation(
                parent: _intro,
                curve: const Interval(0, 0.5, curve: Curves.easeOutCubic),
              ),
            ),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.72, end: 1).animate(
            CurvedAnimation(
              parent: _intro,
              curve: const Interval(0, 0.62, curve: Curves.easeOutBack),
            ),
          ),
          child: const AppLogo(size: 54),
        ),
      ),
    );
  }

  /// 品牌名：逐字从下方浮现，整行缓慢上下浮动。
  Widget _buildBrand(TextStyle style) {
    return AnimatedBuilder(
      animation: _float,
      builder: (context, _) {
        // 正弦式上下浮动（±3px，平滑往返）
        final dy = math.sin(_float.value * 2 * math.pi) * 3;
        return Transform.translate(
          offset: Offset(0, dy),
          child: _StaggeredText(
            text: 'ArchoeraMusic',
            style: style,
            intro: _intro,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    _startAnimations();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 主色径向光晕（静态氛围，入场淡入）
          FadeTransition(
            opacity: Tween<double>(begin: 0, end: 1).animate(
              CurvedAnimation(
                parent: _intro,
                curve: const Interval(0, 0.55, curve: Curves.easeOut),
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.7, -0.8),
                  radius: 1.1,
                  colors: [
                    scheme.primary.withValues(alpha: 0.20),
                    scheme.primary.withValues(alpha: 0.05),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildLogo(),
                const SizedBox(height: 24),
                _buildBrand(
                  TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 10),
                // 版权署名 + 技术栈（延迟淡入 + 轻微上滑，两行）
                FadeTransition(
                  opacity: Tween<double>(begin: 0, end: 1).animate(
                    CurvedAnimation(
                      parent: _intro,
                      curve: const Interval(0.55, 0.95, curve: Curves.easeOut),
                    ),
                  ),
                  child: SlideTransition(
                    position:
                        Tween<Offset>(
                          begin: const Offset(0, 0.06),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: _intro,
                            curve: const Interval(
                              0.55,
                              0.95,
                              curve: Curves.easeOut,
                            ),
                          ),
                        ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Archoera Music © | BetaStudio2',
                          style: TextStyle(
                            fontSize: 12,
                            letterSpacing: 3,
                            color: scheme.onSurfaceVariant.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Powered By Flutter',
                          style: TextStyle(
                            fontSize: 12,
                            letterSpacing: 3,
                            color: scheme.onSurfaceVariant.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                // 加载指示：3 颗脉冲圆点
                _LoadingDots(
                  animation: _pulse,
                  color: scheme.primary.withValues(alpha: 0.9),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 逐字浮现文字（每字从下方上移 + 淡入，错开节奏——「文字上下」特效）。
class _StaggeredText extends StatelessWidget {
  const _StaggeredText({
    required this.text,
    required this.style,
    required this.intro,
  });

  final String text;
  final TextStyle style;
  final Animation<double> intro;

  @override
  Widget build(BuildContext context) {
    final chars = text.split('');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < chars.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1.5),
            child: _StaggeredChar(
              char: chars[i],
              style: style,
              intro: intro,
              delay: i * 0.038,
            ),
          ),
      ],
    );
  }
}

/// 单个字符：局部时间 = `(intro - delay) / 0.42`，从下方 18px 上移 + 淡入。
class _StaggeredChar extends StatelessWidget {
  const _StaggeredChar({
    required this.char,
    required this.style,
    required this.intro,
    required this.delay,
  });

  final String char;
  final TextStyle style;
  final Animation<double> intro;
  final double delay;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: intro,
      builder: (context, _) {
        final local = ((intro.value - delay) / 0.42).clamp(0.0, 1.0);
        final t = Curves.easeOutCubic.transform(local);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 18 * (1 - t)),
            child: Text(char, style: style),
          ),
        );
      },
    );
  }
}

/// 3 颗脉冲加载圆点（参考 Mineradio `startup.html`：1.05s 循环，
/// 相位错开，0–70% 透明度 0.2→1→0.2，35% 处上移 3px）。
class _LoadingDots extends StatelessWidget {
  const _LoadingDots({required this.animation, required this.color});

  final Animation<double> animation;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = (t - i * 0.14) % 1.0;
            final double opacity;
            final double dy;
            if (phase < 0.35) {
              final p = phase / 0.35;
              opacity = 0.2 + 0.8 * Curves.easeOut.transform(p);
              dy = -3.0 * Curves.easeOut.transform(p);
            } else if (phase < 0.70) {
              final p = (phase - 0.35) / 0.35;
              opacity = 1.0 - 0.8 * Curves.easeIn.transform(p);
              dy = -3.0 * (1.0 - Curves.easeIn.transform(p));
            } else {
              opacity = 0.2;
              dy = 0.0;
            }
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 3.5),
              width: 5,
              height: 5,
              child: Transform.translate(
                offset: Offset(0, dy),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: opacity),
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
