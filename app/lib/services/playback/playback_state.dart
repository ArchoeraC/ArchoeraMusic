// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放状态模型（UI 层只读）与播放模式常量。
///
/// 从 `playback_notifier.dart` 拆出：纯数据类 + 常量，不依赖引擎与 Riverpod。
library;

import '../netease/track.dart';
import 'fft_frame.dart';

/// 播放模式（对齐原项目 RepeatMode 并补回 'off'）：
/// - `'off'` 顺序播放——播到队列末尾**自动暂停**，不回绕；
/// - `'list'` 列表循环——列表播完从头再来；
/// - `'one'` 单曲循环。
///
/// 默认仍是 `'list'`（与历史行为一致），三态按 [repeatModeCycle] 顺序轮换。
const repeatModeCycle = ['off', 'list', 'one'];

/// 播放模式文案。
const repeatModeLabels = <String, String>{
  'off': '顺序播放',
  'list': '列表循环',
  'one': '单曲循环',
};

/// 顺序播放（`off`）时当前是否已到队列末尾——到此应自动暂停而非回绕续播。
bool isSequentialQueueEnd(String repeatMode, int queueIndex, int queueLength) =>
    repeatMode == 'off' && queueLength > 0 && queueIndex >= queueLength - 1;

/// 播放状态（UI 层只读）。
class PlaybackState {
  const PlaybackState({
    this.source,
    this.title,
    this.subtitle,
    this.trackId,
    this.track,
    this.quality = 'hq',
    this.sessionId,
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.trackEndStopCount = 0,
    this.logs = const [],
    this.fft,
    this.queue = const [],
    this.queueIndex = -1,
    this.repeatMode = 'list',
    this.shuffle = false,
    this.buffering = false,
    this.volume = 1.0,
  });

  /// 引擎转码源（本地文件路径 / 在线 URL）。
  final String? source;

  /// 展示标题（播放条/全屏播放器用；缺省回退 source）。
  final String? title;

  /// 展示副标题（歌手等）。
  final String? subtitle;

  /// 曲目 id（列表 playingId 高亮用；本地文件无 id 时为空）。
  final String? trackId;

  /// 当前曲目（音质切换等需要平台/品质信息；本地文件时为 null）。
  final Track? track;

  /// 当前音质档位（lq/sq/hq/lossless/hi-res）。
  final String quality;

  final String? sessionId;
  final bool playing;
  final Duration position;
  final Duration duration;

  /// 曲尾「到时暂停」计数：睡眠定时置位 `stopAtTrackEnd` 后，当前曲**自然
  /// 到达末帧**（引擎 `player:ended`）时原地暂停、不续播下一曲，并 +1。
  /// 定时器监听该计数增长即可确认「播完当前曲」已收尾（见 sleep_timer.dart）。
  final int trackEndStopCount;

  final List<String> logs;

  /// 最近一帧 FFT 频谱（128 bins [0,1]，对数映射 80~2000Hz）。
  final FftFrame? fft;

  /// 播放队列（当前列表，UI 只读；原项目 queue store 对应物）。
  final List<Track> queue;

  /// 当前曲目在队列中的索引（-1 = 未在队列中）。
  final int queueIndex;

  /// 播放模式（repeatModeCycle：'list' 列表循环 / 'one' 单曲循环）。
  final String repeatMode;

  /// 随机播放开关（on = 洗牌队列，当前曲置顶）。
  final bool shuffle;

  /// 缓冲/加载中（引擎转码、音源解析期间为 true，进入播放后置 false）。
  final bool buffering;

  /// 播放音量（0~1；用户音量落
  /// AppPrefs，退出确认弹窗的 duck 为临时值，关闭弹窗即恢复）。
  final double volume;

  /// 队列是否非空（切歌按钮可用性）。
  bool get hasQueue => queue.isNotEmpty;

  /// 队列中正在播放的曲目（未在队列时返回 null）。
  Track? get currentQueueTrack =>
      queueIndex >= 0 && queueIndex < queue.length ? queue[queueIndex] : null;

  /// copyWith 哨兵：允许把 [fft] 显式置空。
  static const Object _unset = Object();

  PlaybackState copyWith({
    Object? source = _unset,
    Object? title = _unset,
    Object? subtitle = _unset,
    Object? trackId = _unset,
    Object? track = _unset,
    String? quality,
    Object? sessionId = _unset,
    bool? playing,
    Duration? position,
    Duration? duration,
    int? trackEndStopCount,
    List<String>? logs,
    Object? fft = _unset,
    List<Track>? queue,
    Object? queueIndex = _unset,
    String? repeatMode,
    bool? shuffle,
    bool? buffering,
    double? volume,
  }) {
    return PlaybackState(
      source: identical(source, _unset) ? this.source : source as String?,
      title: identical(title, _unset) ? this.title : title as String?,
      subtitle: identical(subtitle, _unset)
          ? this.subtitle
          : subtitle as String?,
      trackId: identical(trackId, _unset) ? this.trackId : trackId as String?,
      track: identical(track, _unset) ? this.track : track as Track?,
      quality: quality ?? this.quality,
      sessionId: identical(sessionId, _unset)
          ? this.sessionId
          : sessionId as String?,
      playing: playing ?? this.playing,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      trackEndStopCount: trackEndStopCount ?? this.trackEndStopCount,
      logs: logs ?? this.logs,
      fft: identical(fft, _unset) ? this.fft : fft as FftFrame?,
      queue: queue ?? this.queue,
      queueIndex: identical(queueIndex, _unset)
          ? this.queueIndex
          : queueIndex as int,
      repeatMode: repeatMode ?? this.repeatMode,
      shuffle: shuffle ?? this.shuffle,
      buffering: buffering ?? this.buffering,
      volume: volume ?? this.volume,
    );
  }
}
