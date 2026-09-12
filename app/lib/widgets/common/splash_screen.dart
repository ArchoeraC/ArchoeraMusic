// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

import '../layout/app_logo.dart';

part 'splash_screen/splash_screen_widgets.dart';

/// 启动动画（品牌 Splash）。
///
/// 动效：
/// - Logo：上滑渐亮（`easeOutExpo`），不再有呼吸/闪烁；
/// - 品牌名：逐字从下方浮现（错开节奏）；
/// - 底部小字：固定于窗口最底部，延迟上滑渐显（终态约 0.4 透明度）。
/// 背景为深色氛围 + 主色径向光晕（静态）。由外层 [SplashGate] 控制淡出；
/// 引擎加载期的静态覆盖见 `linux/runner/my_application.cc`。
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  /// 入场编排（1s：Logo 上滑 + 文字逐字浮现 + 底部小字）。
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
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
      _intro.forward();
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _buildSplashScreen(context);
}
