part of 'easter_egg.dart';

/// 愚人节特供「整活模式」的全局开关 + 触发/投降语义。
///
/// 与十个「千万别点」不可逆彩蛋不同：本模式**可逆**——激活后应用「倒放」
/// （整屏左右镜像 + 操作反向），并持久化保留，直到用户点击浮动的
/// 「我投降」按钮（[surrender]）才恢复。
class AprilFoolsNotifier extends StateNotifier<bool> {
  AprilFoolsNotifier(this._ref) : super(_initialActive(_ref));

  final Ref _ref;

  /// 首次构造时的激活态：安全模式/环境覆盖优先，否则读持久化偏好。
  static bool _initialActive(Ref ref) {
    if (kEasterEggSafeMode) return false;
    final force = _forceEnv();
    if (force != null) return force;
    final prefs = ref.read(appPrefsProvider);
    return prefs.aprilFoolsEnabled && prefs.aprilFools;
  }

  /// 环境覆盖：`ARCHOERA_EGG_FOOL=1` 强制开启 / `=0` 强制关闭；
  /// 其它值或未设置返回 null（走正常触发逻辑）。
  static bool? _forceEnv() {
    final raw = Platform.environment['ARCHOERA_EGG_FOOL'];
    if (raw == '1') return true;
    if (raw == '0') return false;
    return null;
  }

  /// 整活模式是否激活（= [state]）。
  bool get active => state;

  /// 依当前时间与持久化状态决定是否（重新）激活；幂等。
  ///
  /// 4/1 且当年未投降 → 激活；已激活 → 重申保留；投降/非 4/1 → 关闭。
  void maybeAutoActivate(DateTime now) {
    final prefs = _ref.read(appPrefsProvider);
    final desired = shouldAutoActivate(
      now: now,
      active: state,
      surrenderedYear: prefs.aprilFoolsSurrenderedYear,
      safeMode: kEasterEggSafeMode,
      force: _forceEnv(),
      enabled: prefs.aprilFoolsEnabled,
    );
    if (desired == state) return;
    state = desired;
    _persist(active: desired);
  }

  /// 用户点击「我投降」：关闭整活模式、记录投降年份（当年不再自动开启），
  /// 并弹出「愚人节快乐」提示。
  void surrender() {
    final year = DateTime.now().year;
    state = false;
    _persist(active: false, surrenderedYear: year);
    toast(_ref.read(l10nProvider).aprilFoolsSurrenderToast);
  }

  /// 硬关闭（不记录投降年份）：安全模式 / 内部清理用。
  void disable() {
    if (!state) return;
    state = false;
    _persist(active: false);
  }

  /// 设置页开关：是否允许整活。关闭时若正在整活也立即恢复。
  void setEnabled(bool value) {
    final notifier = _ref.read(appPrefsProvider.notifier);
    notifier.setAprilFoolsEnabled(value);
    if (!value && state) {
      state = false;
      notifier.setAprilFools(false);
    }
  }

  /// 「以后不再整活」：立即关闭并永久禁用自动激活。
  void disableForever() {
    state = false;
    _ref.read(appPrefsProvider.notifier)
      ..setAprilFools(false)
      ..setAprilFoolsEnabled(false);
    toast(_ref.read(l10nProvider).aprilFoolsDisabledToast);
  }

  void _persist({bool? active, int? surrenderedYear}) {
    final notifier = _ref.read(appPrefsProvider.notifier);
    if (active != null) notifier.setAprilFools(active);
    if (surrenderedYear != null) {
      notifier.setAprilFoolsSurrenderedYear(surrenderedYear);
    }
  }
}

final aprilFoolsProvider = StateNotifierProvider<AprilFoolsNotifier, bool>(
  (ref) => AprilFoolsNotifier(ref),
);

/// 整活模式的根宿主：包在整棵 UI（含 Navigator）外层。
///
/// 激活时：
///   - 整屏左右镜像（[Transform] + `transformHitTests: true`，点击跟随镜像）；
///   - 安装 `PrimaryScrollController` + [PrankScrollController]（预期机制）；
///   - 顶层滚轮反向层 [_AprilFoolsWheelInverter]（实际生效的滚轮反转——路由
///     注入的 `PrimaryScrollController` 会遮蔽外层控制器，见该类注释）；
///   - 叠加浮动的「我投降」按钮（**在镜像之外**，不被倒放）。
///
/// 未激活时原样透传 [child]（无镜像、无控制器、无按钮），恢复干净界面。
class AprilFoolsHost extends ConsumerStatefulWidget {
  const AprilFoolsHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AprilFoolsHost> createState() => _AprilFoolsHostState();
}

class _AprilFoolsHostState extends ConsumerState<AprilFoolsHost> {
  /// 仅在激活期间存在的滚动控制器（停用时释放）。
  PrankScrollController? _scroll;

  @override
  void initState() {
    super.initState();
    // 与裸 notifier 初始对齐，供叶子组件在首帧即读到正确状态。
    aprilFoolsActiveNotifier.value = ref.read(aprilFoolsProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(aprilFoolsProvider.notifier).maybeAutoActivate(DateTime.now());
    });
  }

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  PrankScrollController _ensureScroll() =>
      _scroll ??= PrankScrollController(debugLabel: 'april-fools');

  /// 释放控制器：延后到下一帧，避免仍在树上的 ScrollPosition 被立即销毁。
  void _releaseScroll() {
    final controller = _scroll;
    if (controller == null) return;
    _scroll = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  }

  @override
  Widget build(BuildContext context) {
    // 同步裸 notifier（非 Consumer 的叶子组件据此反应）。用 ref.listen 而非
    // 在 build 内直接赋值，避免在构建期同步 notifyListeners 触发重建。
    ref.listen<bool>(aprilFoolsProvider, (bool? _, bool next) {
      aprilFoolsActiveNotifier.value = next;
    });
    final active = ref.watch(aprilFoolsProvider);

    if (!active) {
      _releaseScroll();
      return widget.child;
    }

    final mirrored = Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()..setEntry(0, 0, -1.0),
      transformHitTests: true, // 点击跟随镜像后的视觉位置
      child: PrimaryScrollController(
        controller: _ensureScroll(),
        automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
        scrollDirection: Axis.vertical,
        child: widget.child,
      ),
    );

    return Stack(
      children: [
        Positioned.fill(child: mirrored),
        // 滚轮反向拦截层：Navigator 的每个路由都会注入自己的
        // PrimaryScrollController（移动端平台集），在桌面上会遮蔽外层控制器，
        // 导致上方安装的 PrimaryScrollController 无法被路由内的 ScrollView
        // 继承。故在最顶层放一个命中测试最先到达的 [Listener]：抢到
        // PointerSignalResolver 后按指针位置找到 ScrollPosition 手动反向滚动。
        const Positioned.fill(child: _AprilFoolsWheelInverter()),
        // 「我投降」在镜像之外（Stack 顶层、不参与 Transform）。
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: 16),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SButton(
                      label: context.l10n.aprilFoolsSurrender,
                      variant: SButtonVariant.error,
                      size: SButtonSize.large,
                      onPressed: () =>
                          ref.read(aprilFoolsProvider.notifier).surrender(),
                    ),
                    const SizedBox(height: 4),
                    // 整活态下界面是反的、设置很难进；此处直接提供「永久关闭」。
                    TextButton(
                      onPressed: () => ref
                          .read(aprilFoolsProvider.notifier)
                          .disableForever(),
                      child: Text(
                        context.l10n.aprilFoolsDisableNoMore,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 整活模式的全局滚轮反向层（覆盖在整棵 UI 之上，命中测试最先到达）。
///
/// 原理：`PointerSignalResolver` 只执行**第一个**注册的回调；本层位于 Stack
/// 顶层，指针信号命中路径最先到达，注册回调即抢在下方 `Scrollable` 之前。
/// 回调里按指针位置命中测试找到最近的 `ScrollPosition`，把滚轮 delta 取反后
/// 直接 `pointerScroll`（若直接依赖外层 `PrimaryScrollController`，会被每个
/// 路由注入的路由级控制器遮蔽，桌面上不生效）。
class _AprilFoolsWheelInverter extends StatelessWidget {
  const _AprilFoolsWheelInverter();

  @override
  Widget build(BuildContext context) {
    return Listener(
      // translucent：仅拦截指针信号，不吞掉下层点击 / 悬停。
      behavior: HitTestBehavior.translucent,
      onPointerSignal: _onSignal,
    );
  }

  void _onSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (
      PointerEvent resolved,
    ) {
      final ScrollPosition? position = _positionAt(resolved);
      if (position == null) return;
      final double delta = _signalDelta(
        position.axisDirection,
        event.scrollDelta,
      );
      if (delta == 0) return;
      position.pointerScroll(-delta); // 反向
    });
  }

  /// 按指针位置命中测试，取路径上最近的 `ScrollPosition`（最深优先）。
  static ScrollPosition? _positionAt(PointerEvent event) {
    final HitTestResult result = HitTestResult();
    RendererBinding.instance.hitTestInView(
      result,
      event.position,
      event.viewId,
    );
    for (final HitTestEntry entry in result.path) {
      final Object target = entry.target;
      if (target is RenderViewportBase) {
        final ViewportOffset offset = target.offset;
        if (offset is ScrollPosition) return offset;
      }
    }
    return null;
  }

  /// 与 `Scrollable` 内部一致的滚轮 delta 计算（按轴向与方向符号）。
  static double _signalDelta(AxisDirection axis, Offset scrollDelta) {
    return switch (axis) {
      AxisDirection.up => -scrollDelta.dy,
      AxisDirection.down => scrollDelta.dy,
      AxisDirection.left => -scrollDelta.dx,
      AxisDirection.right => scrollDelta.dx,
    };
  }
}
