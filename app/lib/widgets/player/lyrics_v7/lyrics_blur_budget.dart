// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词失焦的「帧预算守卫」。
///
/// 失焦的成本几乎全在光栅线程：本机 headless 基准（900×600、26 行、连续滚动）
/// 逐行失焦是 **28.5ms/帧**，而无失焦只要 **6.3ms** —— 16.7ms 的帧预算直接爆掉。
/// 而不同机器差一个数量级（独显 / 核显 / 软件光栅 / Windows 上 Impeller 的
/// blur 实现与 Skia 不同，见 flutter#191207），**没法在编译期猜**，只能运行时量。
///
/// 语义刻意保守：
/// - 只在「光栅超预算 **且 UI 线程正常**」时记账 —— 这样不会把加载/解码这类
///   与我们无关的卡顿算进来（那是 UI 线程的锅）；
/// - 要连续 [minJankFrames] 帧超预算（[windowFrames] 窗口内）才建议降级；
/// - 降级只发生一次，由调用方 latch（不做来回抖动）。
///
/// 纯函数式记账，不依赖 Flutter binding，便于单测。
class LyricsBlurBudget {
  LyricsBlurBudget({
    this.budgetMs = 14.0,
    this.uiBudgetMs = 8.0,
    this.windowFrames = 48,
    this.minJankFrames = 30,
  });

  /// 单帧光栅时间预算（毫秒）：超过就算这一帧「吃不住失焦」。
  final double budgetMs;

  /// 同一帧的 UI 线程时间上限（毫秒）：超过说明卡在 UI 线程（构建/布局），
  /// 不是失焦的锅，不计入。
  final double uiBudgetMs;

  /// 采样窗口（帧）。
  final int windowFrames;

  /// 窗口内至少这么多帧超预算才建议降级。
  final int minJankFrames;

  final List<bool> _jank = <bool>[];

  /// 记录一帧耗时，返回是否建议降级。
  ///
  /// 建议降级后调用方应 latch 并 [reset]（避免刚降级就对旧窗口重复判定）。
  bool onFrame(double rasterMs, {double uiMs = 0}) {
    _jank.add(rasterMs > budgetMs && uiMs <= uiBudgetMs);
    if (_jank.length > windowFrames) _jank.removeAt(0);
    if (_jank.length < windowFrames) return false;
    return _jank.where((jank) => jank).length >= minJankFrames;
  }

  void reset() => _jank.clear();

  /// 当前窗口内的记账帧数（诊断/测试用）。
  int get sampledFrames => _jank.length;

  /// 当前窗口内的掉帧数（诊断/测试用）。
  int get jankFrames => _jank.where((jank) => jank).length;
}
