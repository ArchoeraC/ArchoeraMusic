// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放页布局切换时的共享元素（封面 / 曲目信息 / 歌词）。
///
/// 布局各自排版，但把三类内容包进 [PlayerSharedElementBoundary] 并共用页面
/// 下发的 [GlobalKey]。切换布局时，[PlayerLayoutSwitcher] 只负责测量旧/新
/// 边界的矩形，然后让**新布局的真实元素**从旧矩形变换到自身矩形（位置 +
/// 尺寸补间）；不截图、不复制内容，因此中间帧也是新布局的样式与实时歌词。
///
/// 目标矩形全部来自布局实际的 `RenderBox`，不写死屏幕坐标。
library;

import 'package:material_ui/material_ui.dart';

/// 参与位置补间的共享元素。
enum PlayerSharedElement { cover, info, lyrics }

/// 播放页布局切换的时长与曲线（对齐 SPlayer-Next 的 View Transitions：
/// 500ms、`cubic-bezier(0.4, 0, 0.2, 1)`）。
const Duration kPlayerLayoutTransitionDuration = Duration(milliseconds: 500);
const Cubic kPlayerLayoutTransitionCurve = Cubic(0.4, 0.0, 0.2, 1.0);

/// 单个共享元素从旧矩形到新布局自然矩形的状态。
///
/// [natural] 是新布局中元素的实际矩形；[animated] 是当前要绘制到的矩形。
/// 两者使用同一坐标系（播放页局部坐标），由 [PlayerLayoutSwitcher] 统一
/// 测量并随动画更新。
class PlayerSharedElementTransform {
  const PlayerSharedElementTransform({
    required this.natural,
    required this.animated,
  });

  final Rect natural;
  final Rect animated;

  double get _scaleX =>
      natural.width == 0 ? 1.0 : animated.width / natural.width;
  double get _scaleY =>
      natural.height == 0 ? 1.0 : animated.height / natural.height;

  /// 封面按 `object-fit: cover` 语义等比缩放（不拉伸画面），其余元素按矩形
  /// 非等比缩放（对文字/歌词来说等价于两端字号与行宽的连续过渡）。
  double get _coverScale => _scaleX > _scaleY ? _scaleX : _scaleY;

  /// Transform 的相对位移：子级布局原点在 [natural] 的左上角，所以这里要
  /// 先把页面中心换算回相对坐标，再减去自然尺寸中心。
  Offset get _coverOrigin {
    final s = _coverScale;
    return Offset(
      animated.center.dx - natural.left - natural.width * s / 2,
      animated.center.dy - natural.top - natural.height * s / 2,
    );
  }

  /// 相对自然矩形的位移与缩放。
  Matrix4 matrixFor(PlayerSharedElement kind) {
    if (kind == PlayerSharedElement.cover) {
      final s = _coverScale;
      final origin = _coverOrigin;
      return Matrix4.identity()
        ..translateByDouble(origin.dx, origin.dy, 0, 1)
        ..scaleByDouble(s, s, 1, 1);
    }
    return Matrix4.identity()
      ..translateByDouble(
        animated.left - natural.left,
        animated.top - natural.top,
        0,
        1,
      )
      ..scaleByDouble(_scaleX, _scaleY, 1, 1);
  }

  /// 封面的裁切矩形（自然坐标；配合等比缩放实现 cover 裁切）。
  Rect get coverClipRect {
    final s = _coverScale;
    final origin = _coverOrigin;
    return Rect.fromLTWH(
      (animated.left - natural.left - origin.dx) / s,
      (animated.top - natural.top - origin.dy) / s,
      animated.width / s,
      animated.height / s,
    );
  }
}

/// 单个布局 id 的共享元素边界 key。
///
/// 过渡期间旧、新布局会同时挂载，因此 key 必须按布局 id 区分；同一布局内
/// 三类元素各一份，保证 `GlobalKey` 不冲突。
class PlayerSharedElementKeys {
  PlayerSharedElementKeys(String layoutId)
    : _keys = {
        for (final kind in PlayerSharedElement.values)
          kind: GlobalKey(debugLabel: 'player-shared-$layoutId-${kind.name}'),
      };

  final Map<PlayerSharedElement, GlobalKey> _keys;

  GlobalKey operator [](PlayerSharedElement kind) => _keys[kind]!;
}

/// 下发给共享元素的过渡状态。
///
/// - `hidden`：旧布局退场时隐藏其共享元素（新布局的 live 元素接管）；
/// - `transforms`：新布局的共享元素当前应绘制到的矩形。
class PlayerSharedElementScope extends InheritedWidget {
  const PlayerSharedElementScope({
    super.key,
    required this.hidden,
    this.transforms =
        const <PlayerSharedElement, PlayerSharedElementTransform>{},
    required super.child,
  });

  final bool hidden;
  final Map<PlayerSharedElement, PlayerSharedElementTransform> transforms;

  static PlayerSharedElementScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerSharedElementScope>();

  static bool hiddenOf(BuildContext context) =>
      maybeOf(context)?.hidden ?? false;

  static PlayerSharedElementTransform? transformOf(
    BuildContext context,
    PlayerSharedElement kind,
  ) => maybeOf(context)?.transforms[kind];

  @override
  bool updateShouldNotify(PlayerSharedElementScope oldWidget) =>
      oldWidget.hidden != hidden || oldWidget.transforms != transforms;
}

/// 共享元素边界：稳定 key + 独立重绘层，并在过渡中按变换绘制。
class PlayerSharedElementBoundary extends StatelessWidget {
  const PlayerSharedElementBoundary({
    super.key,
    required this.kind,
    required this.boundaryKey,
    required this.child,
  });

  final PlayerSharedElement kind;
  final GlobalKey boundaryKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final hidden = PlayerSharedElementScope.hiddenOf(context);
    final transform = PlayerSharedElementScope.transformOf(context, kind);
    Widget content = RepaintBoundary(key: boundaryKey, child: child);
    if (!hidden && transform != null) {
      if (kind == PlayerSharedElement.cover) {
        // 等比缩放 + 裁切，避免封面在方形/整幅面板之间移动时被拉伸。
        content = ClipRect(
          clipper: _CoverClip(transform.coverClipRect),
          child: content,
        );
      }
      content = Transform(
        alignment: Alignment.topLeft,
        transform: transform.matrixFor(kind),
        child: content,
      );
    }
    return Opacity(opacity: hidden ? 0 : 1, child: content);
  }
}

/// 封面共享元素的裁切矩形（自然坐标）。
class _CoverClip extends CustomClipper<Rect> {
  const _CoverClip(this.rect);

  final Rect rect;

  @override
  Rect getClip(Size size) => rect;

  @override
  bool shouldReclip(_CoverClip oldClipper) => oldClipper.rect != rect;
}
