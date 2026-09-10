// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 系统媒体会话宿主（facade §7.3 / bridge §3.5 P2）：
/// 把 `playbackProvider` 状态同步到 OS 媒体会话（MPRIS/SMTC/Now Playing），
/// 并把 OS 派发的媒体命令（媒体键/蓝牙 AVRCP/桌面面板）转回播放控制器。
///
/// 仅依赖 `SystemMedia` 接口；桥接缺能力时为空实现，静默降级。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../widgets/common/toast.dart';
import '../playback/playback_notifier.dart';
import '../playback/playback_state.dart';
import 'platform_capabilities.dart';
import 'platform_failure.dart';
import 'system_media.dart';

/// 媒体会话宿主：挂载即开始同步；随 ProviderScope 释放。
class MediaSessionHost extends ConsumerStatefulWidget {
  const MediaSessionHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<MediaSessionHost> createState() => _MediaSessionHostState();
}

class _MediaSessionHostState extends ConsumerState<MediaSessionHost> {
  late final SystemMedia _media = ref.read(platformCapabilitiesProvider).media;
  StreamSubscription<MediaEvent>? _cmdSub;
  StreamSubscription<PlatformCapabilityFailure>? _failSub;

  String? _trackKey;
  MediaPlaybackState _lastState = MediaPlaybackState.stopped;
  String? _lastSessionId;
  int _lastPosMs = 0;
  bool _lostToasted = false;

  @override
  void initState() {
    super.initState();
    _cmdSub = _media.commands.listen(_onCommand);
    _failSub = _media.failures.listen((f) {
      if (f.lost && !_lostToasted) {
        _lostToasted = true;
        toast(
          ref.read(l10nProvider).toastMediaSessionLost,
          type: ToastType.warning,
        );
      } else if (!f.lost) {
        debugPrint('[media] 平台能力失败: $f');
      }
    });
    // 初始同步（应用启动即恢复的播放状态）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync(ref.read(playbackProvider));
    });
  }

  @override
  void dispose() {
    _cmdSub?.cancel();
    _failSub?.cancel();
    super.dispose();
  }

  void _onCommand(MediaEvent e) {
    final n = ref.read(playbackProvider.notifier);
    final s = ref.read(playbackProvider);
    switch (e) {
      case MediaCommandEvent(:final command):
        switch (command) {
          case MediaCommand.play:
            if (!s.playing) n.toggle();
          case MediaCommand.pause:
            if (s.playing) n.toggle();
          case MediaCommand.toggle:
            n.toggle();
          case MediaCommand.stop:
            unawaited(n.stop());
          case MediaCommand.next:
            debugPrint('[media] cmd next (queue=${s.queue.length} idx=${s.queueIndex})');
            unawaited(n.playNext());
          case MediaCommand.previous:
            debugPrint('[media] cmd previous (queue=${s.queue.length} idx=${s.queueIndex})');
            unawaited(n.playPrevious());
        }
      case MediaSeekEvent(:final offsetMs):
        unawaited(n.seek(s.position + Duration(milliseconds: offsetMs)));
      case MediaSeekToEvent(:final positionMs):
        unawaited(n.seek(Duration(milliseconds: positionMs)));
    }
  }

  /// 同步曲目元数据 + 播放态；位置仅在状态/会话变化或跳变 >1.5s 时推送，
  /// 避免 50ms 位置事件反复刷 PropertiesChanged（原生侧自行外推位置）。
  void _sync(PlaybackState s) {
    final trackKey = '${s.source}|${s.title}|${s.subtitle}|${s.trackId}';
    if (trackKey != _trackKey) {
      _trackKey = trackKey;
      if (s.source == null) {
        unawaited(_media.clearNowPlaying());
      } else {
        unawaited(
          _media.setNowPlaying(
            NowPlayingTrack(
              title: s.title ?? s.source ?? '',
              artist: s.subtitle,
              album: s.track?.album?.name,
              durationMs: s.duration.inMilliseconds > 0
                  ? s.duration.inMilliseconds
                  : null,
              artUrl: s.track?.cover ?? s.track?.album?.cover,
            ),
          ),
        );
      }
      // 切歌即推送一次播放态（含新位置基准）
      _pushPlayback(s);
      return;
    }

    final state = s.playing
        ? MediaPlaybackState.playing
        : (s.sessionId == null
              ? MediaPlaybackState.stopped
              : MediaPlaybackState.paused);
    final jumped = (s.position.inMilliseconds - _lastPosMs).abs() > 1500;
    if (state != _lastState || s.sessionId != _lastSessionId || jumped) {
      _pushPlayback(s);
    }
  }

  void _pushPlayback(PlaybackState s) {
    final state = s.playing
        ? MediaPlaybackState.playing
        : (s.sessionId == null
              ? MediaPlaybackState.stopped
              : MediaPlaybackState.paused);
    _lastState = state;
    _lastSessionId = s.sessionId;
    _lastPosMs = s.position.inMilliseconds;
    unawaited(
      _media.setPlaybackState(
        state,
        positionMs: s.position.inMilliseconds,
        volume: s.volume,
        loopOne: s.repeatMode == 'one',
        shuffle: s.shuffle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(playbackProvider, (prev, next) => _sync(next));
    return widget.child;
  }
}
