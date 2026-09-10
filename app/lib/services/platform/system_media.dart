// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// SystemMedia 契约：OS 媒体会话（MPRIS / SMTC / Now Playing / MediaSession）。
///
/// 蓝牙耳机 AVRCP / 键盘媒体键 → OS 统一收进媒体会话 → [commands] 流派发；
/// 语法差异由 OS 与各平台实现消化，主程序只依赖本接口。
///
/// 见 docs/platform-capability-facade.md §2.1 / §7.3。
library;

import 'dart:async';

import 'platform_failure.dart';

/// OS 媒体会话派发的统一命令。
enum MediaCommand { play, pause, toggle, stop, next, previous }

/// 媒体命令（含参数命令：seek）。
sealed class MediaEvent {
  const MediaEvent();
}

/// 无参命令。
class MediaCommandEvent extends MediaEvent {
  const MediaCommandEvent(this.command);

  final MediaCommand command;
}

/// Seek 相对位移（正=前进，负=后退），单位毫秒。
class MediaSeekEvent extends MediaEvent {
  const MediaSeekEvent(this.offsetMs);

  final int offsetMs;
}

/// Seek 到绝对位置，单位毫秒。
class MediaSeekToEvent extends MediaEvent {
  const MediaSeekToEvent(this.positionMs);

  final int positionMs;
}

/// 当前曲目元数据（媒体会话展示用）。
class NowPlayingTrack {
  const NowPlayingTrack({
    required this.title,
    this.artist,
    this.album,
    this.durationMs,
    this.artUrl,
  });

  final String title;

  /// 歌手（多人以 " / " 连接由调用方拼好）。
  final String? artist;

  final String? album;

  /// 曲目时长毫秒（未知为 null）。
  final int? durationMs;

  /// 封面图 URL（MPRIS artUrl；无封面 null）。
  final String? artUrl;
}

/// 播放状态（媒体会话 PlaybackStatus 语义）。
enum MediaPlaybackState { stopped, playing, paused }

/// OS 媒体会话接口。
abstract interface class SystemMedia {
  /// 注册/更新当前曲目（切歌时调用；[track] 为 null 等价 clearNowPlaying）。
  /// 返回是否成功；失败时调用方/监听者应显式告警（facade §5）。
  Future<bool> setNowPlaying(NowPlayingTrack? track);

  /// 清除当前曲目（媒体会话不再展示）。
  Future<bool> clearNowPlaying();

  /// 更新播放状态与位置（播放/暂停/位置事件时调用）。
  /// [volume]/[loopOne]/[shuffle] 供 MPRIS 属性展示（可空 = 沿用上次）。
  Future<bool> setPlaybackState(
    MediaPlaybackState state, {
    int positionMs = 0,
    double speed = 1.0,
    double? volume,
    bool? loopOne,
    bool? shuffle,
  });

  /// OS 派发下来的媒体命令流（广播语义，多订阅者互不影响）。
  Stream<MediaEvent> get commands;

  /// 执行失败 / 后端断连上抛（如 D-Bus 断连 → toast「媒体会话已断开」）。
  Stream<PlatformCapabilityFailure> get failures;

  /// 释放底层资源（D-Bus 服务名/对象导出等）；幂等。
  Future<void> dispose();
}

/// 空实现：不注册任何媒体会话（耳机/媒体键无效），静默降级。
class NoopSystemMedia implements SystemMedia {
  static final NoopSystemMedia instance = NoopSystemMedia._();

  NoopSystemMedia._();

  @override
  Future<bool> setNowPlaying(NowPlayingTrack? track) async => false;

  @override
  Future<bool> clearNowPlaying() async => false;

  @override
  Future<bool> setPlaybackState(
    MediaPlaybackState state, {
    int positionMs = 0,
    double speed = 1.0,
    double? volume,
    bool? loopOne,
    bool? shuffle,
  }) async => false;

  @override
  Stream<MediaEvent> get commands => const Stream.empty();

  @override
  Stream<PlatformCapabilityFailure> get failures => const Stream.empty();

  @override
  Future<void> dispose() async {}
}
