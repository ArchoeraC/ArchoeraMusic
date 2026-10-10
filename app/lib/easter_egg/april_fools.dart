part of 'easter_egg.dart';

/// 愚人节特供「奇怪的特效」的**会话内**全局开关 + 一次性开启语义。
///
/// 与十个「千万别点」不可逆彩蛋不同：本特效**可逆**（点「我投降」即恢复），但
/// 开启机会**只有一次**——仅在 4/1 当天于设置页出现，开启后设置项立即消失；
/// 且无论手动关闭、重启应用还是点击「我投降」，设置项都不会再出现，直到次年
/// 4/1。特效本身不落盘：重启应用即结束（见 [shouldOfferAprilFools] 与
/// [aprilFoolsUsedYear]，后者只记录「今年的机会是否已被消耗」）。
class AprilFoolsNotifier extends StateNotifier<bool> {
  AprilFoolsNotifier(this._ref) : super(_initialActive());

  final Ref _ref;

  /// 首次构造时的激活态：仅安全模式 / 环境覆盖参与（特效跨重启不保留）。
  static bool _initialActive() {
    if (kEasterEggSafeMode) return false;
    return _forceEnv() ?? false;
  }

  /// 环境覆盖：`ARCHOERA_EGG_FOOL=1` 强制开启 / `=0` 强制关闭；
  /// 其它值或未设置返回 null（走正常逻辑）。
  static bool? _forceEnv() {
    final raw = Platform.environment['ARCHOERA_EGG_FOOL'];
    if (raw == '1') return true;
    if (raw == '0') return false;
    return null;
  }

  /// 特效是否激活（= [state]）。
  bool get active => state;

  /// 设置页是否应显示「奇怪的特效」开关（仅 4/1 且今年尚未开启过）。
  bool shouldOffer(DateTime now) => shouldOfferAprilFools(
    now: now,
    usedYear: _ref.read(appPrefsProvider).aprilFoolsUsedYear,
    safeMode: kEasterEggSafeMode,
    force: _forceEnv(),
  );

  /// 用户开启「奇怪的特效」：本次运行内激活，并**消耗**今年的开启机会
  /// （写入 [year] 后设置项立即消失；重启 / 投降都不会令其恢复）。
  void activate(int year) {
    if (state) return;
    state = true;
    _ref.read(appPrefsProvider.notifier).setAprilFoolsUsedYear(year);
  }

  /// 用户点击「我投降」：关闭特效并弹出「愚人节快乐」提示。
  ///
  /// 不恢复开启机会——设置项直到次年 4/1 才会再次出现。
  void surrender() {
    if (!state) return;
    state = false;
    toast(_ref.read(l10nProvider).aprilFoolsSurrenderToast);
  }

  /// 硬关闭（不写偏好）：安全模式 / 内部清理用。
  void disable() {
    if (!state) return;
    state = false;
  }
}

final aprilFoolsProvider = StateNotifierProvider<AprilFoolsNotifier, bool>(
  (ref) => AprilFoolsNotifier(ref),
);

/// 「奇怪的特效」的根宿主：包在整棵 UI（含 Navigator）外层。
///
/// 激活时：
///   - 整屏左右镜像（[Transform] + `transformHitTests: true`，点击跟随镜像）；
///   - 安装 `PrimaryScrollController` + [PrankScrollController]（预期机制）；
///   - 顶层滚轮反向层 [_AprilFoolsWheelInverter]（实际生效的滚轮反转——路由
///     注入的 `PrimaryScrollController` 会遮蔽外层控制器，见该类注释）；
///   - 顶部居中叠加一面**白旗**按钮（**在镜像之外**，不被倒放；不含文字，
///     投降文案仅作无障碍标签；避开底部播放条，不遮挡播放/切歌等按键）。
///
/// 未激活时保持**同一树形**、仅以恒等变换 + `PrimaryScrollController.none`
/// 透传 [child]（无镜像、无控制器、无按钮），既恢复干净界面，又避免切换时
/// 重建下游子树（否则解脱整活时「愚人节快乐」提示会被重载打断）。
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
    if (!active) _releaseScroll();

    // 未激活也保持**同一树形**（Stack > Transform > PrimaryScrollController
    // > child），只切换属性：若把 child 移到不同层级，Flutter 会销毁重建整棵
    // 下游子树（含 ToastOverlay 与各启动门）——解除整活时「愚人节快乐」提示会
    // 被这次重载打断、启动门亦可能重放。恒等 Matrix4 属纯平移，
    // RenderTransform 会短路、不产生变换层，未激活时几乎零开销。
    return Stack(
      children: [
        Positioned.fill(
          child: Transform(
            alignment: Alignment.center,
            // 未激活为恒等变换（镜像关闭）。
            transform: active
                ? (Matrix4.identity()..setEntry(0, 0, -1.0))
                : Matrix4.identity(),
            transformHitTests: true, // 点击跟随镜像后的视觉位置
            child: active
                ? PrimaryScrollController(
                    controller: _ensureScroll(),
                    automaticallyInheritForPlatforms: TargetPlatform.values
                        .toSet(),
                    scrollDirection: Axis.vertical,
                    child: widget.child,
                  )
                : PrimaryScrollController.none(child: widget.child),
          ),
        ),
        // 滚轮反向拦截层：Navigator 的每个路由都会注入自己的
        // PrimaryScrollController（移动端平台集），在桌面上会遮蔽外层控制器，
        // 导致上方安装的 PrimaryScrollController 无法被路由内的 ScrollView
        // 继承。故在最顶层放一个命中测试最先到达的 [Listener]：抢到
        // PointerSignalResolver 后按指针位置找到 ScrollPosition 手动反向滚动。
        if (active) const Positioned.fill(child: _AprilFoolsWheelInverter()),
        // 「投降」在镜像之外（Stack 顶层、不参与 Transform）。
        // 只显示一面白旗（无文字，投降文案仅作无障碍标签）；置于
        // **顶部居中**（导航栏中段空白区 / 播放页顶栏中段），避开底部播放条
        // 的播放 / 上一首 / 下一首等按键；`heightFactor: 1` 令悬浮层只占按钮
        // 自身高度，不覆盖整屏命中区。
        if (active)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
              bottom: false,
              minimum: const EdgeInsets.only(top: 12),
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: 1,
                child: Material(
                  type: MaterialType.transparency,
                  // 按钮本身只显示一面白旗（无文字）；投降文案仅作无障碍标签。
                  // 不用 Tooltip：宿主位于 Navigator 之上，缺少 Overlay 祖先。
                  child: Semantics(
                    label: context.l10n.aprilFoolsSurrender,
                    child: SButton(
                      label: '🏳️',
                      variant: SButtonVariant.secondary,
                      size: SButtonSize.medium,
                      round: true,
                      onPressed: () =>
                          ref.read(aprilFoolsProvider.notifier).surrender(),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 「奇怪的特效」的全局滚轮反向层（覆盖在整棵 UI 之上，命中测试最先到达）。
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
