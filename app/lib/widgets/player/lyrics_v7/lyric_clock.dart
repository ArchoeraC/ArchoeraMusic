// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词播放时钟：把 ~20Hz 的播放位置事件插值到 vsync。
///
/// 引擎的播放位置由引擎事件推送，正常约 50ms 一次。逐字扫亮 / 滚动都直接
/// 读这个位置，若不做插值，扫亮边界就按 20Hz 跳变（可见阶梯）。上游 AMLL
/// 由 rAF 每帧驱动 `currentTime`，天然是平滑的。
///
/// 本类以「事件位置 + 本地累加时间」外推：每次收到权威位置就重新锚定，
/// 两次事件之间按 vsync 间隔推进。外推上限 [kMaxExtrapolateMs] 防止事件
/// 停更（缓冲 / seek / 后台）时歌词跑到前面去。
///
/// 纯 Dart，无 Flutter 依赖，可单测。
library;

/// 单次外推上限（毫秒）。
///
/// 取 150ms（3 个事件周期）：既覆盖偶发丢帧，又能在事件停更（缓冲 / seek /
/// 后台）时迅速「刹住」——事件恢复后至多回退一个上限，肉眼不可辨。
const int kMaxExtrapolateMs = 150;

/// 歌词播放时钟。
class LyricClock {
  int _anchorMs = 0;
  bool _playing = false;
  double _elapsedSec = 0;
  int _valueMs = 0;

  /// 当前用于渲染的播放位置（毫秒）。
  int get valueMs => _valueMs;

  /// 最近一次权威锚点位置（毫秒）。
  int get anchorMs => _anchorMs;

  /// 是否处于播放推进态（暂停/未播放时不外推）。
  bool get playing => _playing;

  /// 是否仍在推进（供 ticker 决定常开）。
  bool get isRunning => _playing;

  /// 用新的权威播放位置重新锚定。
  ///
  /// 位置或播放状态**变化**才重置外推计时；同一位置的重复上报不清空外推
  /// （配合 [kMaxExtrapolateMs]，事件停更时最多领先一个上限后停住）。
  void anchor(int positionMs, {required bool playing}) {
    if (_anchorMs == positionMs && _playing == playing) return;
    reset(positionMs, playing: playing);
  }

  /// 立即跳到某位置并清空外推。
  void reset(int positionMs, {required bool playing}) {
    _anchorMs = positionMs;
    _playing = playing;
    _elapsedSec = 0;
    _valueMs = positionMs;
  }

  /// 推进 [dtSec] 秒并刷新 [valueMs]。
  ///
  /// 非播放态直接等于锚点位置（暂停时歌词应静止在权威位置）。
  void tick(double dtSec) {
    if (!_playing || dtSec <= 0) {
      _valueMs = _anchorMs;
      return;
    }
    _elapsedSec += dtSec;
    final extra = (_elapsedSec * 1000).clamp(0.0, kMaxExtrapolateMs.toDouble());
    _valueMs = _anchorMs + extra.round();
  }
}
