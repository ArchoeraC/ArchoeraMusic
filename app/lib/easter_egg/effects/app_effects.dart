part of '../easter_egg.dart';

// ── 外观/应用类彩蛋（除 #2 外一律永久生效、不还原）────────────────────

/// #3 界面放大至 800%：永久生效（重启前保持放大）。
Future<void> _zoom800(EasterEggContext ctx) async {
  final ref = ctx.ref;
  if (ref == null) return;
  ref.read(easterEggVisualProvider.notifier).setZoom(8.0);
}

/// #4 深色与浅色互切：约 3 秒内每 120ms 切一次，结束后**停在切换到的模式**
/// （不还原原模式）。
Future<void> _themeStrobe(EasterEggContext ctx) async {
  final ref = ctx.ref;
  if (ref == null) return;
  final notifier = ref.read(themeModeProvider.notifier);
  final timer = Timer.periodic(const Duration(milliseconds: 120), (_) {
    final next = ref.read(themeModeProvider) == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;
    notifier.setMode(next);
  });
  await Future<void>.delayed(const Duration(seconds: 3));
  timer.cancel();
}

/// #5 直接关闭软件：走统一退出入口（落盘 + 桥接收尾 + exit(0)）。
Future<void> _quitNow(EasterEggContext ctx) async {
  final ref = ctx.ref;
  if (ref == null) return;
  if (kEasterEggSafeMode) {
    debugPrint('[easter-egg] quit_now 跳过（安全模式）');
    return;
  }
  await quitApplication(ref);
}

/// #7 反转界面（左右镜像）：视觉左右翻转，但**点击位置不变**；永久生效。
Future<void> _mirror(EasterEggContext ctx) async {
  final ref = ctx.ref;
  if (ref == null) return;
  ref.read(easterEggVisualProvider.notifier).setMirror(true);
}

/// #10 颜色反转：整界面 RGB 取反（黑白互补）；永久生效。
Future<void> _invertColors(EasterEggContext ctx) async {
  final ref = ctx.ref;
  if (ref == null) return;
  ref.read(easterEggVisualProvider.notifier).setInvert(true);
}
