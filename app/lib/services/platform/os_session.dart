// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// ArchoeraOS 会话宿主：把「播放器即系统」的会话状态接进应用。
///
/// - 订阅合成器会话事件（媒体键经既有媒体命令流复用；电源键/亮度/电池/会话态
///   在此观察）；
/// - `shutting_down` / `suspending` 前暂停播放；
/// - 把播放器音量镜像给合成器（`apl_os_set_volume`），使系统侧状态一致。
///
/// 未运行于 `archoera-shell` 时 `SystemOsSession` 为空实现，静默降级。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../playback/playback_notifier.dart';
import '../playback/playback_state.dart';
import 'platform_capabilities.dart';
import 'system_os.dart';

class OsSessionHost extends ConsumerStatefulWidget {
  const OsSessionHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<OsSessionHost> createState() => _OsSessionHostState();
}

class _OsSessionHostState extends ConsumerState<OsSessionHost> {
  late final SystemOsSession _os = ref.read(platformCapabilitiesProvider).os;
  final List<StreamSubscription<Object?>> _subs = [];

  bool _eventsOn = false;
  int _lastVolumePercent = -1;

  @override
  void initState() {
    super.initState();
    if (!_os.available) {
      debugPrint('[os] ArchoeraOS 会话不可用（未运行于 archoera-shell）');
      return;
    }

    _subs.add(_os.session.listen(_onSession));
    _subs.add(
      _os.battery.listen(
        (b) => debugPrint(
          '[os] battery present=${b.present} ${b.percent}% '
          '${b.charging ? 'charging' : 'discharging'}',
        ),
      ),
    );
    _subs.add(_os.screenEnabled.listen((e) => debugPrint('[os] screen=$e')));
    _subs.add(_os.powerKey.listen((k) => debugPrint('[os] power_key=$k')));

    _eventsOn = _os.setEvents(true) == 0;
    debugPrint('[os] 会话事件订阅: $_eventsOn');

    // 初始音量镜像（应用启动即恢复的播放音量）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pushVolume(ref.read(playbackProvider));
    });
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    if (_eventsOn) _os.setEvents(false);
    super.dispose();
  }

  /// 关机 / 挂起前暂停播放（给用户与状态保存留出余地）。
  void _onSession(OsSessionState state) {
    debugPrint('[os] session=$state');
    if (state == OsSessionState.ready) return;
    final notifier = ref.read(playbackProvider.notifier);
    final playing = ref.read(playbackProvider).playing;
    if (playing) notifier.toggle();
  }

  /// 把播放器音量镜像给合成器（仅变化时下发，避免回声式抖动）。
  void _pushVolume(PlaybackState state) {
    if (!_eventsOn) return;
    final percent = (state.volume * 100).round().clamp(0, 100);
    if (percent == _lastVolumePercent) return;
    _lastVolumePercent = percent;
    _os.setVolume(percent);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(playbackProvider, (_, next) => _pushVolume(next));
    return widget.child;
  }
}
