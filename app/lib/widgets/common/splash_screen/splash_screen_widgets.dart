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
          _buildGlow(scheme),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildLogo(),
                const SizedBox(height: 20),
                _buildBrand(
                  TextStyle(
                    // 启动页字标专用显示字体（可变字重，见 pubspec「Manrope」）。
                    fontFamily: 'Manrope',
                    fontVariations: const [FontVariation('wght', 700)],
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          _buildFooter(scheme),
        ],
      ),
    );
  }

  /// 背景径向光晕（主色，静态，随入场淡入）。
  Widget _buildGlow(ColorScheme scheme) {
    return FadeTransition(
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
    );
  }

  Widget _buildLogo() {
    final rise = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0, 0.5, curve: Curves.easeOutExpo),
    );
    return FadeTransition(
      opacity: Tween<double>(begin: 0, end: 1).animate(rise),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.16),
          end: Offset.zero,
        ).animate(rise),
        child: const AppLogo(size: 72),
      ),
    );
  }

  Widget _buildBrand(TextStyle style) {
    return _StaggeredText(text: 'ArchoeraMusic', style: style, intro: _intro);
  }

  /// 底部小字：固定贴窗口最底（32px），延迟上滑渐显，终态约 0.4 透明度。
  Widget _buildFooter(ColorScheme scheme) {
    final fade = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.35, 0.85, curve: Curves.easeOut),
    );
    return Positioned(
      left: 0,
      right: 0,
      bottom: 32,
      child: FadeTransition(
        opacity: Tween<double>(begin: 0, end: 0.4).animate(fade),
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.6), end: Offset.zero)
              .animate(
                CurvedAnimation(
                  parent: _intro,
                  curve: const Interval(0.35, 0.85, curve: Curves.easeOutExpo),
                ),
              ),
          child: Text(
            'ArchoeraMusic © BetaStudio2 · Powered by Flutter',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 2,
              color: scheme.onSurfaceVariant,
            ),
          ),
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
