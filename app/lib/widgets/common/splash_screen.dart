// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../layout/app_logo.dart';

part 'splash_screen/splash_screen_widgets.dart';

/// 启动动画（品牌 Splash）。
///
/// 布局参照 SPlayer-Next（`index.html` 的 splash）：
/// - **居中**：Logo（主色辉光，弹出式淡入/上滑/`easeOutBack` 放大）+ 品牌名；
/// - **底部 64px**：3 颗脉冲加载圆点；
/// - **最底 28px**：小字（版权 + Powered By）——放在**窗口底部**。
///
/// 自有元素：Logo 周围扩散的**涟漪环**（呼应播放页水纹背景）、品牌名逐字浮现。
/// 由外层 [SplashGate] 控制淡出；性能模式（`disableAnimations`）下全部动画
/// 停掉、呈现静态画面（省 CPU/电量）。
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

  /// Logo 涟漪环扩散（2.4s 循环）。
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
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
      _ripple.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _intro.dispose();
    _float.dispose();
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _buildSplashScreen(context);
}
