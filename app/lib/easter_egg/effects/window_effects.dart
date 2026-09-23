part of '../easter_egg.dart';

// ── 窗口类彩蛋（依赖 window_manager；失败静默忽略）────────────────────

/// #1 系统「未响应」：永久阻塞 UI isolate（不进事件循环），桌面会把窗口标记
/// 为「未响应」；唯一出路是强制结束进程（与警告文案一致）。
///
/// 说明：此处用 `sleep` 阻塞而非忙等——同样冻住事件循环/渲染，但不吃满 CPU。
/// 音频引擎跑在原生线程，界面卡死后音乐仍会继续播放。
Future<void> _notResponding(EasterEggContext ctx) async {
  if (kEasterEggSafeMode) {
    debugPrint('[easter-egg] not_responding 跳过（安全模式）');
    return;
  }
  debugPrint('[easter-egg] not_responding：界面将永久卡住（强杀进程方可退出）');
  // ignore: literal_only_boolean_expressions
  while (true) {
    sleep(const Duration(seconds: 30));
  }
}

/// #2 「最小化且不可还原」（限时）：最小化后监听「还原」事件并立刻再最小化；
/// [kMinimizeTrapDuration] 结束后释放并还原窗口。（唯一会恢复的彩蛋）
const Duration kMinimizeTrapDuration = Duration(seconds: 6);

class _ReMinimizeListener with WindowListener {
  @override
  void onWindowRestore() {
    unawaited(windowManager.minimize());
  }
}

Future<void> _minimizeTrap(EasterEggContext ctx) async {
  final listener = _ReMinimizeListener();
  windowManager.addListener(listener);
  try {
    await windowManager.minimize();
    await Future<void>.delayed(kMinimizeTrapDuration);
  } catch (_) {
    // 无窗口系统：忽略
  } finally {
    windowManager.removeListener(listener);
    try {
      await windowManager.restore();
      await windowManager.focus();
    } catch (_) {}
  }
}

/// 探测「程序能否移动自身窗口」：Wayland 合成器下客户端不被允许。
Future<bool> _windowMoveSupported() async {
  try {
    final p0 = await windowManager.getPosition();
    await windowManager.setPosition(Offset(p0.dx + 1, p0.dy + 1));
    final p1 = await windowManager.getPosition();
    final ok = (p1 - p0).distance > 0.5;
    if (ok) await windowManager.setPosition(p0);
    return ok;
  } catch (_) {
    return false;
  }
}

/// #6 所有组件躲避鼠标：开启全局开关，装了 MouseDodge 的组件（按钮 / 条目 /
/// 图标按钮等）会朝远离指针的方向累积位移且不还原。永久生效。
Future<void> _fleeMouse(EasterEggContext ctx) async {
  easterEggDodge.value = true;
}

/// #8 在桌面内滚动：能移窗时窗口沿曲线滚动，Wayland 下退化为界面内容滚动。
/// 永久生效（持续滚动，不还原）。
Future<void> _desktopScroll(EasterEggContext ctx) async {
  final native = await _windowMoveSupported();
  const frame = Duration(milliseconds: 50);

  if (native) {
    Offset original;
    try {
      original = await windowManager.getPosition();
    } catch (_) {
      return;
    }
    var t = 0.0;
    while (true) {
      t += 0.16;
      try {
        await windowManager.setPosition(
          Offset(original.dx + 460 * math.sin(t), original.dy + 300 * math.sin(t * 1.7 + 1.1)),
        );
      } catch (_) {
        return;
      }
      await Future<void>.delayed(frame);
    }
  }

  // Wayland 回退：滚动界面内容（窗口本身动不了）。
  final ref = ctx.ref;
  if (ref == null) return;
  final notifier = ref.read(easterEggVisualProvider.notifier);
  var t = 0.0;
  while (true) {
    t += 0.14;
    notifier.setContentShift(
      Offset(220 * math.sin(t), 150 * math.cos(t * 1.3)),
    );
    await Future<void>.delayed(frame);
  }
}
