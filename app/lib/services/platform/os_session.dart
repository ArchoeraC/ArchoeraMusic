// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// ArchoeraOS 会话宿主：把「播放器即系统」的会话状态接进应用。
///
/// - 订阅合成器会话事件（媒体键经既有媒体命令流复用；电源键/亮度/电池/会话态
///   在此观察并写入状态，供设置「系统」分区等 UI 读取）；
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

/// ArchoeraOS 会话状态快照（不可变）。
@immutable
class OsState {
  const OsState({
    this.capabilities = 0,
    this.brightness,
    this.battery,
    this.screenEnabled,
    this.session = OsSessionState.ready,
    this.output,
  });

  /// 会话能力位图（archoera_shell_v1 capability；0 = 未知/未订阅）。
  final int capabilities;

  /// 当前亮度（0-100；null = 未知）。
  final int? brightness;

  /// 当前电池状态（null = 未知/无电池）。
  final OsBatteryState? battery;

  /// 屏幕开关（DPMS；null = 未知）。
  final bool? screenEnabled;

  /// 会话态。
  final OsSessionState session;

  /// 主输出状态（null = 未知/未接入）。
  final OsOutputState? output;

  static const Object _unset = Object();

  OsState copyWith({
    int? capabilities,
    Object? brightness = _unset,
    Object? battery = _unset,
    Object? screenEnabled = _unset,
    OsSessionState? session,
    Object? output = _unset,
  }) {
    return OsState(
      capabilities: capabilities ?? this.capabilities,
      brightness: identical(brightness, _unset)
          ? this.brightness
          : brightness as int?,
      battery: identical(battery, _unset)
          ? this.battery
          : battery as OsBatteryState?,
      screenEnabled: identical(screenEnabled, _unset)
          ? this.screenEnabled
          : screenEnabled as bool?,
      session: session ?? this.session,
      output: identical(output, _unset)
          ? this.output
          : output as OsOutputState?,
    );
  }
}

/// 会话状态 Notifier（由 [OsSessionHost] 写入）。
class OsSessionNotifier extends Notifier<OsState> {
  @override
  OsState build() => const OsState();

  void setCapabilities(int v) => state = state.copyWith(capabilities: v);
  void setBrightness(int? v) => state = state.copyWith(brightness: v);
  void setBattery(OsBatteryState? v) => state = state.copyWith(battery: v);
  void setScreenEnabled(bool? v) => state = state.copyWith(screenEnabled: v);
  void setSession(OsSessionState v) => state = state.copyWith(session: v);
  void setOutput(OsOutputState v) => state = state.copyWith(output: v);
}

/// 会话状态总源。
final osSessionProvider = NotifierProvider<OsSessionNotifier, OsState>(
  OsSessionNotifier.new,
);

/// 派生只读 provider（供 UI 订阅，避免整体重建）。
final osCapabilitiesProvider = Provider<int>(
  (ref) => ref.watch(osSessionProvider.select((s) => s.capabilities)),
);
final osBrightnessProvider = Provider<int?>(
  (ref) => ref.watch(osSessionProvider.select((s) => s.brightness)),
);
final osBatteryProvider = Provider<OsBatteryState?>(
  (ref) => ref.watch(osSessionProvider.select((s) => s.battery)),
);
final osScreenEnabledProvider = Provider<bool?>(
  (ref) => ref.watch(osSessionProvider.select((s) => s.screenEnabled)),
);
final osSessionStateProvider = Provider<OsSessionState>(
  (ref) => ref.watch(osSessionProvider.select((s) => s.session)),
);
final osOutputProvider = Provider<OsOutputState?>(
  (ref) => ref.watch(osSessionProvider.select((s) => s.output)),
);

/// 会话能力是否可用（供设置导航 gate；测试可覆盖）。
final osSessionAvailableProvider = Provider<bool>(
  (ref) => ref.watch(platformCapabilitiesProvider).osSessionAvailable,
);

/// 会话控制面（请求入口；测试可覆盖为假实现）。
final osSessionControllerProvider = Provider<SystemOsSession>(
  (ref) => ref.watch(platformCapabilitiesProvider).os,
);

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

  OsSessionNotifier get _osState => ref.read(osSessionProvider.notifier);

  @override
  void initState() {
    super.initState();
    if (!_os.available) {
      debugPrint('[os] ArchoeraOS 会话不可用（未运行于 archoera-shell）');
      return;
    }

    _subs.add(_os.capabilities.listen(_osState.setCapabilities));
    _subs.add(_os.brightness.listen(_osState.setBrightness));
    _subs.add(
      _os.battery.listen((b) {
        _osState.setBattery(b);
        debugPrint(
          '[os] battery present=${b.present} ${b.percent}% '
          '${b.charging ? 'charging' : 'discharging'}',
        );
      }),
    );
    _subs.add(
      _os.screenEnabled.listen((e) {
        _osState.setScreenEnabled(e);
        debugPrint('[os] screen=$e');
      }),
    );
    _subs.add(
      _os.session.listen((s) {
        _osState.setSession(s);
        _onSession(s);
      }),
    );
    _subs.add(_os.powerKey.listen((k) => debugPrint('[os] power_key=$k')));
    _subs.add(
      _os.output.listen((o) {
        _osState.setOutput(o);
        debugPrint(
          '[os] output ${o.width}x${o.height} @ '
          '${(o.refreshMillihz / 1000).toStringAsFixed(1)}Hz '
          'scale=${o.scale} rotate=${o.rotationDegrees}',
        );
      }),
    );

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
