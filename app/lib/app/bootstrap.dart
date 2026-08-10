import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/downloader/download_controller.dart';
import '../services/playback/playback_notifier.dart';
import '../stores/providers.dart';
import '../widgets/common/splash_screen.dart';

/// 启动时初始化网易云登录态（匿名注册 + 读取持久化账号）。
class AuthBootstrap extends ConsumerStatefulWidget {
  const AuthBootstrap({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AuthBootstrap> createState() => _AuthBootstrapState();
}

class _AuthBootstrapState extends ConsumerState<AuthBootstrap> {
  @override
  void initState() {
    super.initState();
    // 异步初始化：不阻塞首帧渲染
    Future<void>.microtask(() async {
      try {
        // 并行：恢复播放现场（含位置续播）与网易云登录态初始化互不阻塞
        await Future.wait([
          ref.read(playbackProvider.notifier).restore(),
          ref.read(neteaseAuthProvider.notifier).init(),
        ]);
      } catch (e, s) {
        // 现场恢复 / 登录态初始化异常不阻塞后续初始化（下载引擎等），
        // 恢复失败时现场保留暂停态，用户点播放即可重试。
        debugPrint('[bootstrap] 初始化异常: $e\n$s');
      }
      // 下载引擎初始化（触发 build → init 注册回调 + 注入已持久化会话）。
      // 放在登录态恢复之后：注入 Rust 的 session/cookie 始终取最新状态。
      ref.read(downloadControllerProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 登录态变化（含启动 init 后）时同步红心集合；
    // 酷狗 provider 仅在登录/登出时 notify，不会因普通 API 调用触发。
    ref.listen(neteaseAuthProvider, (_, _) {
      ref.read(likeControllerProvider).sync();
      // 登录/登出后把最新 cookie 重新注入下载引擎（幂等）
      ref.read(downloadControllerProvider.notifier).syncSessions();
    });
    ref.listen(kugouApiProvider, (_, _) {
      ref.read(likeControllerProvider).sync();
      ref.read(downloadControllerProvider.notifier).syncSessions();
    });
    return widget.child;
  }
}

/// 启动过渡门：品牌 Splash 覆盖整个应用，1.9s 后 550ms 淡出（轻微上移缩放）
/// 过渡到主界面，动画结束才从树中移除。
class SplashGate extends StatefulWidget {
  const SplashGate({super.key, required this.child});

  final Widget child;

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate>
    with SingleTickerProviderStateMixin {
  /// 淡出过渡（0 → 1）。注意：控制器初始 value 为 0，
  /// 因此 opacity 必须用 `1 → 0` 的 Tween——否则首帧 Splash 透明，
  /// 露出底部主界面（曾出现的「先进主页再进动画」bug）。
  late final AnimationController _dismiss = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 550),
  );

  bool _removed = false;

  /// 性能模式（MediaQuery.disableAnimations）。initState 阶段不允许依赖
  /// MediaQuery（dependOnInheritedWidgetOfExactType 断言），在 build 中读取。
  bool _noAnim = false;

  @override
  void initState() {
    super.initState();
    // 性能模式（MediaQuery.disableAnimations）：跳过 550ms 淡出，到点直接移除。
    // 注：_noAnim 在首次 build 时读取（挂载流程 build 先于本 delayed 回调）。
    Future<void>.delayed(const Duration(milliseconds: 1900), () {
      if (!mounted) return;
      if (_noAnim) {
        setState(() => _removed = true);
      } else {
        _dismiss.forward().then((_) {
          if (mounted) setState(() => _removed = true);
        });
      }
    });
  }

  @override
  void dispose() {
    _dismiss.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 性能模式在 build 中读取（initState 不允许依赖 MediaQuery）
    _noAnim = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (!_removed)
          IgnorePointer(
            child: FadeTransition(
              opacity: Tween<double>(begin: 1, end: 0).animate(
                CurvedAnimation(
                  parent: _dismiss,
                  curve: Curves.easeInCubic,
                ),
              ),
              child: ScaleTransition(
                scale: Tween<double>(begin: 1, end: 0.98).animate(
                  CurvedAnimation(
                    parent: _dismiss,
                    curve: Curves.easeInCubic,
                  ),
                ),
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: Offset.zero,
                    end: const Offset(0, -0.03),
                  ).animate(CurvedAnimation(
                    parent: _dismiss,
                    curve: Curves.easeInCubic,
                  )),
                  child: const SplashScreen(),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
