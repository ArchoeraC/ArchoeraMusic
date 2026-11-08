// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 设置页「效果预览」小样。
///
/// 全部用 Flutter 实时渲染（无视频解码器）：图片背景、主题 / 封面圆角、
/// 封面切换动效、页面过渡、水纹背景与歌词边缘渐隐。预览图使用
/// `assets/previews/` 下的示例封面 / 壁纸；真实背景图已选择时优先使用。
///
/// 测试环境（`FLUTTER_TEST`）自动关闭循环动画，保持单帧静态，避免
/// `pumpAndSettle` 被无限动画卡住。
library;

import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:material_ui/material_ui.dart';

import '../app/route_transitions/route_transition_registry.dart';
import '../l10n/l10n.dart';
import '../stores/app_prefs.dart';
import '../theme/app_theme.dart';
import '../widgets/common/baked_image_background.dart';
import '../widgets/player/background/ripple_background.dart';
import '../widgets/player/cover_switcher.dart';
import '../widgets/player/lyrics_edge_fade.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';

const _sampleCoverAsset = 'assets/previews/sample_cover.jpg';
const _sampleWallpaperAsset = 'assets/previews/sample_wallpaper.jpg';

/// 预览循环动画是否可用（测试环境关闭，保证 `pumpAndSettle` 能收敛）。
final bool _previewMotionEnabled = !Platform.environment.containsKey(
  'FLUTTER_TEST',
);

/// 预览卡片外壳：小标题 + 可选右上角操作 + 固定高度内容区。
class SettingsPreviewCard extends StatelessWidget {
  const SettingsPreviewCard({
    super.key,
    required this.label,
    required this.child,
    this.trailing,
    this.height = 148,
  });

  final String label;
  final Widget child;
  final Widget? trailing;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.28),
          border: Border.all(color: scheme.outline.withValues(alpha: 0.28)),
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 8, 6),
              child: Row(
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                    ),
                  ),
                  const Spacer(),
                  ?trailing,
                ],
              ),
            ),
            SizedBox(height: height, child: child),
          ],
        ),
      ),
    );
  }
}

/// 示例封面（跟随封面圆角）。
class _SampleCover extends StatelessWidget {
  const _SampleCover({required this.size, required this.radius, this.tint});

  final double size;
  final double radius;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final color = tint;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        image: const DecorationImage(
          image: AssetImage(_sampleCoverAsset),
          fit: BoxFit.cover,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      foregroundDecoration: color == null
          ? null
          : BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              color: color.withValues(alpha: 0.32),
              backgroundBlendMode: BlendMode.overlay,
            ),
    );
  }
}

/// 外观：图片背景 + 模糊 / 遮罩 / 缩放预览。
class BackgroundEffectPreview extends StatelessWidget {
  const BackgroundEffectPreview({super.key, required this.prefs});

  final AppPrefs prefs;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final path = prefs.backgroundImage;
    final file = path != null && File(path).existsSync()
        ? FileImage(File(path))
        : null;
    final ImageProvider provider =
        file ?? const AssetImage(_sampleWallpaperAsset);
    return SettingsPreviewCard(
      label: l10n.settingsPreview,
      height: 150,
      child: Stack(
        fit: StackFit.expand,
        children: [
          BakedImageBackground(
            provider: ResizeImage.resizeIfNeeded(960, 540, provider),
            blurSigma: prefs.backgroundBlur.toDouble(),
            scale: prefs.backgroundScale,
            dim: prefs.backgroundDim,
          ),
          IgnorePointer(child: _MockAppChrome(scheme: scheme)),
        ],
      ),
    );
  }
}

/// 背景预览上的半透明迷你界面（侧栏 + 卡片 + 底栏）。
class _MockAppChrome extends StatelessWidget {
  const _MockAppChrome({required this.scheme});

  final ColorScheme scheme;

  Widget _bar(double width, {double height = 7}) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.32),
      borderRadius: BorderRadius.circular(4),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 38,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                Icon(
                  EtaIcons.music,
                  size: 16,
                  color: Colors.white.withValues(alpha: 0.8),
                ),
                const SizedBox(height: 12),
                for (var i = 0; i < 4; i++) ...[
                  _bar(18, height: 5),
                  const SizedBox(height: 7),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _bar(64, height: 8),
                    const Spacer(),
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.8),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: Row(
                    children: [
                      for (var i = 0; i < 3; i++) ...[
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: Container(
                                    margin: const EdgeInsets.all(7),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.12,
                                      ),
                                      borderRadius: BorderRadius.circular(7),
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    7,
                                    0,
                                    7,
                                    7,
                                  ),
                                  child: _bar(24, height: 5),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (i != 2) const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.26),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _bar(52, height: 5),
                      const SizedBox(width: 6),
                      _bar(32, height: 5),
                      const Spacer(),
                      Icon(
                        EtaIcons.play,
                        size: 14,
                        color: Colors.white.withValues(alpha: 0.8),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 外观：主题色 / 全局着色 / 封面圆角预览。
class ThemeCoverPreview extends StatelessWidget {
  const ThemeCoverPreview({
    super.key,
    required this.prefs,
    this.compact = false,
  });

  final AppPrefs prefs;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final coverSize = compact ? 62.0 : 84.0;
    return SettingsPreviewCard(
      label: l10n.settingsPreview,
      height: compact ? 100 : 132,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
        child: Row(
          children: [
            _SampleCover(size: coverSize, radius: prefs.coverRadius),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.settingsPreviewSampleTrack,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 13 : 14.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    l10n.settingsPreviewSampleArtist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 11 : 12,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          EtaIcons.play,
                          size: 14,
                          color: scheme.onPrimary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      for (final color in [
                        scheme.primary,
                        scheme.secondary,
                        scheme.tertiary,
                        scheme.surfaceContainerHighest,
                      ]) ...[
                        Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: scheme.outline.withValues(alpha: 0.4),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 播放页：封面切换动效预览（scale / slide / fade 循环）。
class CoverTransitionPreview extends StatefulWidget {
  const CoverTransitionPreview({super.key, required this.style});

  final String style;

  @override
  State<CoverTransitionPreview> createState() => _CoverTransitionPreviewState();
}

class _CoverTransitionPreviewState extends State<CoverTransitionPreview> {
  Timer? _timer;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    if (_previewMotionEnabled) {
      _timer = Timer.periodic(const Duration(milliseconds: 2400), (_) {
        if (mounted) setState(() => _tick++);
      });
    }
  }

  @override
  void didUpdateWidget(CoverTransitionPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.style != widget.style) {
      // build 一定会在 didUpdateWidget 之后执行，无需额外 setState。
      _tick++;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return SettingsPreviewCard(
      label: l10n.settingsPreview,
      height: 140,
      trailing: IconButton(
        tooltip: l10n.settingsPreviewReplay,
        icon: Icon(EtaIcons.refresh, size: 18),
        onPressed: () => setState(() => _tick++),
      ),
      child: Center(
        child: SizedBox(
          width: 106,
          height: 106,
          child: CoverSwitcher(
            coverKey: '${widget.style}-$_tick',
            style: widget.style,
            next: true,
            child: _SampleCover(
              size: 106,
              radius: 12,
              tint: _tick.isEven ? scheme.primary : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// 外观：页面路由过渡预览（none / fade / slide / zoom 循环）。
class RouteTransitionPreview extends StatefulWidget {
  const RouteTransitionPreview({super.key, required this.style});

  final String style;

  @override
  State<RouteTransitionPreview> createState() => _RouteTransitionPreviewState();
}

class _RouteTransitionPreviewState extends State<RouteTransitionPreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  Timer? _timer;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
      value: 1,
    );
    if (_previewMotionEnabled) {
      _timer = Timer.periodic(const Duration(milliseconds: 2200), (_) {
        if (mounted) _play();
      });
    }
  }

  void _play() {
    final transition = routeTransitionFor(widget.style);
    _anim.duration = transition.duration == Duration.zero
        ? const Duration(milliseconds: 1)
        : transition.duration;
    _anim.value = 0;
    setState(() => _tick++);
    _anim.forward();
  }

  @override
  void didUpdateWidget(RouteTransitionPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.style != widget.style) {
      _anim.duration =
          routeTransitionFor(widget.style).duration == Duration.zero
          ? const Duration(milliseconds: 1)
          : routeTransitionFor(widget.style).duration;
      _anim.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final transition = routeTransitionFor(widget.style);
    return SettingsPreviewCard(
      label: l10n.settingsPreview,
      height: 140,
      trailing: IconButton(
        tooltip: l10n.settingsPreviewReplay,
        icon: Icon(EtaIcons.refresh, size: 18),
        onPressed: _play,
      ),
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _anim,
          builder: (context, _) {
            final base = _MockRoutePage(index: _tick);
            final entering = _MockRoutePage(index: _tick + 1);
            return Stack(
              fit: StackFit.expand,
              children: [base, transition.build(context, _anim, entering)],
            );
          },
        ),
      ),
    );
  }
}

/// 路由过渡预览用的迷你页面（数字 + 几行占位）。
class _MockRoutePage extends StatelessWidget {
  const _MockRoutePage({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final even = index.isEven;
    final c1 = even ? scheme.primary : scheme.tertiary;
    final c2 = even ? scheme.secondary : scheme.primary;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            c1.withValues(alpha: 0.30),
            c2.withValues(alpha: 0.16),
            scheme.surface.withValues(alpha: 0.9),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.22)),
      ),
      child: Stack(
        children: [
          Positioned(
            right: 16,
            top: 4,
            child: Text(
              '${even ? 1 : 2}',
              style: TextStyle(
                fontSize: 58,
                fontWeight: FontWeight.w800,
                color: c1.withValues(alpha: 0.28),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: c1,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < 3; i++) ...[
                  Container(
                    width: i == 0 ? 120 : (i == 1 ? 88 : 64),
                    height: 6,
                    decoration: BoxDecoration(
                      color: scheme.onSurface.withValues(
                        alpha: 0.25 - i * 0.05,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 5),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 性能 / 渲染：水纹背景预览（使用示例封面，无视频依赖）。
class RippleEffectPreview extends StatelessWidget {
  const RippleEffectPreview({super.key, required this.prefs});

  final AppPrefs prefs;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return SettingsPreviewCard(
      label: l10n.settingsPreview,
      height: 150,
      child: ClipRect(
        child: RippleBackground(
          imageProvider: const AssetImage(_sampleCoverAsset),
          playing: true,
          speed: prefs.playerBgRippleSpeed,
          animate: _previewMotionEnabled && !prefs.performanceMode,
          useShader: _previewMotionEnabled && prefs.rippleShaderEnabled,
          renderScale: prefs.rippleLowRes ? rippleLowResScale : 1.0,
          damageClippedDynamic: prefs.rippleDamageClip,
          fallbackColor: scheme.primary,
        ),
      ),
    );
  }
}

/// 性能 / 渲染：歌词边缘渐隐预览（逐行 / 遮罩 / 关闭）。
class LyricsEdgeFadePreview extends StatelessWidget {
  const LyricsEdgeFadePreview({super.key, required this.mode});

  final String mode;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final texts = [
      l10n.settingsPreviewLyric1,
      l10n.settingsPreviewLyric2,
      l10n.settingsPreviewLyric3,
    ];
    final resolved = lyricsEdgeFadeModeFrom(mode);
    Widget line(int i) {
      final active = i == 1;
      final base = Text(
        texts[i],
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          height: 1.2,
          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          color: active
              ? scheme.primary
              : scheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
      );
      if (resolved != LyricsEdgeFadeMode.wall) return base;
      final t = (i + 0.5) / texts.length;
      return Opacity(opacity: lyricsEdgeFadeAt(t), child: base);
    }

    Widget content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < texts.length; i++) ...[
          line(i),
          if (i != texts.length - 1) const SizedBox(height: 14),
        ],
      ],
    );
    if (resolved == LyricsEdgeFadeMode.shader) {
      content = LyricsEdgeFade(child: content);
    }
    return SettingsPreviewCard(
      label: l10n.settingsPreview,
      height: 132,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
        child: content,
      ),
    );
  }
}
