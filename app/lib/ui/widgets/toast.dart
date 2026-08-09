/// 全局 toast 消息（对齐原项目 SPlayer-Next SToast 经典布局）。
///
/// 布局：顶部居中堆叠；卡片 = 主题背景 + 类型彩色边框 + 底部倒计时进度条；
/// 进入/离开动画 = 淡入 + 下滑（对齐原版 classic 风格）。无关闭按钮、
/// 不拦截点击（纯展示，pointer-events-none）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

/// toast 类型（对齐原项目 ToastType；default/info 同色系）。
enum ToastType { default_, info, success, warning, error }

/// 单条 toast 数据。
class ToastItem {
  ToastItem({
    required this.id,
    required this.type,
    required this.message,
    required this.duration,
  });

  final int id;
  final ToastType type;
  final String message;
  final Duration duration;

  /// 是否处于离开动画（真实移除前短暂保留，供退场过渡）。
  bool leaving = false;
}

/// 全局 toast 控制器：队列 + 自动关闭定时；ToastOverlay 监听渲染。
class ToastController extends ChangeNotifier {
  static const int maxToasts = 5;

  final List<ToastItem> _items = [];
  int _nextId = 0;

  List<ToastItem> get items => List.unmodifiable(_items);

  /// 弹出 toast。满队列时移除最早一条（对齐原版 while length >= max）。
  void show(
    String message, {
    ToastType type = ToastType.default_,
    Duration duration = const Duration(milliseconds: 3000),
  }) {
    while (_items.length >= maxToasts) {
      _items.removeAt(0);
    }
    final item = ToastItem(
      id: _nextId++,
      type: type,
      message: message,
      duration: duration,
    );
    _items.add(item);
    notifyListeners();
    // 自动关闭（与进度条动画时长一致）
    Timer(item.duration, () => dismiss(item.id));
  }

  /// 标记离开动画；动画结束后由 [remove] 真正移除。
  void dismiss(int id) {
    final idx = _items.indexWhere((t) => t.id == id);
    if (idx == -1 || _items[idx].leaving) return;
    _items[idx].leaving = true;
    notifyListeners();
  }

  void remove(int id) {
    final before = _items.length;
    _items.removeWhere((t) => t.id == id);
    if (_items.length != before) notifyListeners();
  }
}

/// 全局单例（应用内唯一，ToastOverlay 注册监听）。
final ToastController toastController = ToastController();

/// 便捷 API：`toast('已复制', type: ToastType.success)`。
void toast(
  String message, {
  ToastType type = ToastType.default_,
  Duration duration = const Duration(milliseconds: 3000),
}) {
  toastController.show(message, type: type, duration: duration);
}

/// 覆盖层宿主：挂在 MaterialApp.builder 最外层，叠在 Navigator 之上，
/// 顶部居中渲染 toast 队列（不拦截下层点击）。
class ToastOverlay extends StatelessWidget {
  const ToastOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        // 顶部居中队列；IgnorePointer 保证纯展示不挡交互
        Positioned(
          top: 24,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: ListenableBuilder(
              listenable: toastController,
              builder: (context, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item in toastController.items)
                    _ToastItemView(key: ValueKey(item.id), item: item),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 单条 toast：进入/离开动画 + 类型样式 + 底部进度条。
class _ToastItemView extends StatefulWidget {
  const _ToastItemView({super.key, required this.item});

  final ToastItem item;

  @override
  State<_ToastItemView> createState() => _ToastItemViewState();
}

class _ToastItemViewState extends State<_ToastItemView>
    with SingleTickerProviderStateMixin {
  /// 进入（0→1）与离开（1→0）共用一个控制器：
  /// 进入动画前 250ms 内完成，时长取控制器 forward 的 250ms 即可。
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );

  late final CurvedAnimation _in = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOut,
  );
  late final CurvedAnimation _out = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeIn,
    reverseCurve: Curves.easeIn,
  );

  bool get _leaving => widget.item.leaving;

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
    // 侦听外部 dismiss（自动关闭定时触发）→ 播离开动画后移除
    toastController.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    toastController.removeListener(_onControllerChanged);
    _ctrl.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (_leaving && !_ctrl.isAnimating && _ctrl.value >= 1) {
      _ctrl.reverse().then((_) {
        if (mounted) toastController.remove(widget.item.id);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // 进度条倒计时：仅类型色动画条（从满到空、左对齐收缩，时长与
    // 自动关闭一致）。不画全宽轨道线，避免文字下方出现一条横线。
    final progress = TweenAnimationBuilder<double>(
      tween: Tween(begin: 1, end: 0),
      duration: widget.item.duration,
      curve: Curves.linear,
      builder: (context, v, _) => Container(
        height: 2,
        color: Colors.transparent,
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: v,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _barColor,
              borderRadius: BorderRadius.circular(2),
            ),
            child: const SizedBox(width: double.infinity, height: 2),
          ),
        ),
      ),
    );

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        // 进入/离开都做透明度过渡；位移方向统一向上
        // （进入：+16→0 从下方升起；离开：0→-16 向上滑出）
        final v = _leaving ? _out.value : _in.value;
        final dy = _leaving ? -16 * (1 - v) : 16 * (1 - v);
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, dy),
            child: child,
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints: const BoxConstraints(minWidth: 200, maxWidth: 420),
        clipBehavior: Clip.antiAlias, // 进度条贴底，裁剪圆角
        decoration: BoxDecoration(
          color: scheme.surfaceBright,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _borderColor, width: 1),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 16,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 文字区：显式 onSurface 颜色（ToastOverlay 位于 Material
            // 之外，不能用默认黑色；留底部空间给进度条）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Text(
                widget.item.message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13.5,
                  color: scheme.onSurface,
                ),
              ),
            ),
            // 底部倒计时进度条（卡片最底部）
            progress,
          ],
        ),
      ),
    );
  }

  /// 类型 → 边框色（对齐原版 classicBorder；default/info 跟随主题主色）
  Color get _borderColor {
    final scheme = Theme.of(context).colorScheme;
    return switch (widget.item.type) {
      ToastType.success => scheme.primary.withValues(alpha: 0.55),
      ToastType.warning => const Color(0xFF6B4A1F),
      ToastType.error => scheme.error.withValues(alpha: 0.6),
      ToastType.default_ || ToastType.info =>
        scheme.primary.withValues(alpha: 0.45),
    };
  }

  /// 类型 → 进度条色（对齐原版 classicBar；default/info 跟随主题主色，
  /// 避免固定蓝色与自定义/系统主题色冲突）
  Color get _barColor {
    final scheme = Theme.of(context).colorScheme;
    return switch (widget.item.type) {
      ToastType.success => const Color(0xFF27AE60),
      ToastType.warning => const Color(0xFFD68910),
      ToastType.error => scheme.error,
      ToastType.default_ || ToastType.info => scheme.primary,
    };
  }
}
