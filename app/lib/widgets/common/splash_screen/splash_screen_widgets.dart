// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../splash_screen.dart';

extension _SplashScreenBuild on _SplashScreenState {
  Widget _buildSplashScreen(BuildContext context) {
    _startAnimations();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 背景：主色径向光晕（静态，入场淡入）。
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
          // 居中：涟漪环 + Logo + 品牌名。
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    _RippleRings(animation: _ripple, color: scheme.primary),
                    _buildLogo(scheme),
                  ],
                ),
                const SizedBox(height: 30),
                _buildBrand(
                  TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          // 底部 64px：加载圆点。
          Positioned(
            left: 0,
            right: 0,
            bottom: 64,
            child: FadeTransition(
              opacity: Tween<double>(begin: 0, end: 1).animate(
                CurvedAnimation(
                  parent: _intro,
                  curve: const Interval(0.55, 0.95, curve: Curves.easeOut),
                ),
              ),
              child: Center(
                child: _LoadingDots(
                  animation: _pulse,
                  color: scheme.primary.withValues(alpha: 0.9),
                ),
              ),
            ),
          ),
          // 最底 28px：小字（版权 + Powered By）——放在窗口底部。
          Positioned(
            left: 0,
            right: 0,
            bottom: 28,
            child: FadeTransition(
              opacity: Tween<double>(begin: 0, end: 0.5).animate(
                CurvedAnimation(
                  parent: _intro,
                  curve: const Interval(0.6, 1.0, curve: Curves.easeOut),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'ArchoeraMusic © BetaStudio2',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      letterSpacing: 3,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Powered By Flutter',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      letterSpacing: 3,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Logo：主色辉光 + 弹出（淡入 / 上滑 / `easeOutBack` 过冲放大）。
  Widget _buildLogo(ColorScheme scheme) {
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
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(54 * 0.3),
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.45),
                  blurRadius: 28,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: const AppLogo(size: 54),
          ),
        ),
      ),
    );
  }

  Widget _buildBrand(TextStyle style) {
    return AnimatedBuilder(
      animation: _float,
      builder: (context, _) {
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
}

/// 涟漪环：从 Logo 中心扩散 3 圈、循环淡出（呼应播放页水纹背景）。
class _RippleRings extends StatelessWidget {
  const _RippleRings({required this.animation, required this.color});

  final Animation<double> animation;
  final Color color;

  static const int _count = 3;
  static const double _base = 60;
  static const double _spread = 84;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) {
          return SizedBox(
            width: _base + _spread,
            height: _base + _spread,
            child: Stack(
              alignment: Alignment.center,
              children: [
                for (var i = 0; i < _count; i++)
                  _ring((animation.value + i / _count) % 1.0),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _ring(double t) {
    final size = _base + t * _spread;
    final opacity = (1 - t) * 0.35;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: color.withValues(alpha: opacity),
          width: 1.5,
        ),
      ),
    );
  }
}

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
