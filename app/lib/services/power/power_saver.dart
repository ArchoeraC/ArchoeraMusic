// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../l10n/l10n.dart';
import '../../stores/app_prefs.dart';
import '../platform/platform_capabilities.dart';
import '../platform/platform_failure.dart';
import '../platform/system_power.dart';
import '../platform/system_window.dart';
import '../playback/playback_notifier.dart';
import '../../widgets/common/toast.dart';
import 'frame_governor.dart';

/// 节能原因（决定目标帧率上限）。
enum PowerSaverReason {
  /// 前台正常渲染（不限制帧率）。
  none,

  /// 窗口最小化 / 隐藏到托盘：5 FPS。
  minimized,

  /// 窗口失焦（同桌面其他应用被聚焦）：1 FPS。
  unfocused,

  /// 屏幕关闭 / 锁屏（Linux D-Bus `ActiveChanged` 信号）：1 FPS。
  screenOff,
}

/// 全局节能模式服务。
///
/// - 窗口最小化 / 失焦 / 屏幕关闭时，通过 [PowerSavingFrameBinding] 自动
///   降低渲染帧率（最小化 5 FPS，失焦 / 熄屏 1 FPS）；
/// - 「禁用系统休眠」仅**在媒体播放中**通过平台能力外观（原生桥接）保持系统
///   唤醒，暂停 / 停止时立即释放，后台播放不中断。
///
/// 全程事件驱动：window_manager 窗口事件 + D-Bus 信号订阅 + Timer 帧合并，
/// 不使用轮询。窗口隐藏 / 屏幕关闭时若引擎已内建停帧（GTK 无 vsync、
/// 显示器关闭等），以引擎内建节能为准，本服务设置的帧率上限只是兜底。
class PowerSaverService with WindowListener {
  PowerSaverService(this._ref, this._power, this._window);

  final Ref _ref;

  /// 平台能力外观（原生桥接）：熄屏订阅 + 休眠抑制（facade §7.2）。
  final SystemPower _power;

  /// 平台能力外观：窗口最小化/失焦事件（桥接可用时优先，否则 window_manager）。
  final SystemWindow _window;

  /// 节能模式总开关（设置持久化，默认开）。
  bool _enabled = true;

  bool _minimized = false;
  bool _focused = true;
  bool _screenOff = false;

  /// 应用内媒体是否正在播放（仅播放中才允许注册唤醒锁）。
  bool _playing = false;

  /// 「禁用系统休眠」设置（默认关，持久化）。
  bool _suppressSleep = false;

  /// 唤醒锁当前实际持有状态（避免重复调用）。
  bool _sleepActive = false;

  StreamSubscription<bool>? _screenSub;
  StreamSubscription<PlatformCapabilityFailure>? _failSub;
  StreamSubscription<SystemWindowState>? _windowSub;

  /// 节流期自愈看门狗：仅当处于非前台节流档位时运行（低频复查真实窗口状态），
  /// 防止锁屏/解锁、失焦/回焦等**事件丢失**导致永久卡在低帧率（重启才恢复）。
  Timer? _watchdog;

  static const Map<PowerSaverReason, Duration> _intervalByReason = {
    PowerSaverReason.minimized: Duration(milliseconds: 200), // 5 FPS
    PowerSaverReason.unfocused: Duration(seconds: 1), // 1 FPS
    PowerSaverReason.screenOff: Duration(seconds: 1), // 1 FPS
  };

  /// 引擎位置事件间隔（ms）按档位映射（engine-event-push-plan §4.1）：
  /// 前台 normal 50ms（与现状等价）/ 最小化 minimized 500ms（2Hz 保底）/
  /// 失焦、熄屏 1000ms（1Hz 保底）。
  static const Map<PowerSaverReason, int> _engineIntervalByReason = {
    PowerSaverReason.none: 50,
    PowerSaverReason.minimized: 500,
    PowerSaverReason.unfocused: 1000,
    PowerSaverReason.screenOff: 1000,
  };

  /// 最近一次已发送的引擎事件间隔（避免每个窗口事件都重复刷命令）。
  int? _lastEngineIntervalMs;

  /// 开始监听窗口状态（并异步订阅平台熄屏/窗口状态）。
  /// window_manager 监听保留：托盘 hide/show 事件 + 桥接未覆盖时的兜底。
  void attach() {
    windowManager.addListener(this);
    unawaited(_attachWindowWatcher());
    unawaited(_attachScreenWatcher());
  }

  /// 经平台能力外观订阅窗口最小化/失焦（桥接 WINDOW_STATE 能力位存在时）。
  /// 失败/缺能力静默回落 window_manager 监听（后台优化类，不打断用户）。
  Future<void> _attachWindowWatcher() async {
    if (_windowSub != null) return;
    final ok = await _window.setEvents(true);
    if (!ok) {
      debugPrint('[power] 桥接窗口状态不可用（回退 window_manager）');
      return;
    }
    _windowSub = _window.state.listen((s) {
      _minimized = s.minimized;
      _focused = s.focused;
      _apply();
    });
  }

  /// 经平台能力外观订阅熄屏状态（原生桥接事件驱动，非轮询）。
  /// 订阅失败 / 能力缺失仅 debug 回落（后台优化类，不打断用户）。
  Future<void> _attachScreenWatcher() async {
    if (_screenSub != null) return;
    final ok = await _power.setScreenEvents(true);
    if (!ok) {
      debugPrint('[power] 熄屏状态订阅不可用（忽略熄屏场景）');
    }
    _screenSub = _power.screenState.listen((active) {
      _screenOff = active;
      _apply();
    });
    _failSub = _power.failures.listen((f) {
      debugPrint('[power] 平台能力失败: $f');
    });
  }

  /// 节能模式总开关（设置页切换，立即生效）。
  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    _apply();
  }

  /// 「禁用系统休眠」设置（默认关）：**仅在应用内媒体正在播放时**才真正
  /// 注册唤醒锁；暂停 / 停止 / 退出时无论开关如何都立即释放，避免
  /// 无媒体播放时系统被无条件强制保持唤醒。
  void setSuppressSleep(bool value) {
    if (_suppressSleep == value) return;
    _suppressSleep = value;
    unawaited(_applySleep());
  }

  /// 应用内媒体播放状态（播放 / 暂停 / 停止）。播放中才允许持有唤醒锁。
  void setPlaying(bool value) {
    if (_playing == value) return;
    _playing = value;
    unawaited(_applySleep());
  }

  /// 按「设置 + 播放中」双条件决定休眠抑制；状态未变化时不重复调用。
  ///
  /// 经平台能力外观（原生桥接）执行：失败时**显式 toast 告警**并回滚状态
  /// （facade §5 降级两档；能力缺失由 Noop 静默降级，不进此路径）。
  Future<void> _applySleep() async {
    final want = _suppressSleep && _playing;
    if (want == _sleepActive) return;
    _sleepActive = want;
    final ok = await _power.setSleepInhibit(want);
    if (!ok) {
      _sleepActive = !want;
      debugPrint('[power] 禁用系统休眠切换失败');
      if (want) {
        toast(_ref.read(l10nProvider).toastSleepInhibitFailed,
            type: ToastType.warning);
      }
    }
  }

  // ── WindowListener ────────────────────────────────────────────

  @override
  void onWindowMinimize() {
    _minimized = true;
    _apply();
  }

  @override
  void onWindowRestore() {
    _minimized = false;
    _screenOff = false; // 恢复 ⇒ 屏幕点亮
    _apply();
  }

  @override
  void onWindowFocus() {
    _focused = true;
    _screenOff = false; // 窗口获得焦点 ⇒ 屏幕必然点亮/未锁屏（修正丢失的熄屏复位）
    _apply();
  }

  @override
  void onWindowBlur() {
    _focused = false;
    _apply();
  }

  @override
  void onWindowEvent(String eventName) {
    // 关闭到托盘（后台播放）按最小化语义降帧；重新显示恢复
    switch (eventName) {
      case 'hide':
        _minimized = true;
        _apply();
      case 'show':
        _minimized = false;
        _screenOff = false; // 重新显示 ⇒ 屏幕点亮
        _apply();
    }
  }

  PowerSaverReason get _reason {
    if (!_enabled) return PowerSaverReason.none;
    if (_minimized) return PowerSaverReason.minimized;
    if (!_focused) return PowerSaverReason.unfocused;
    if (_screenOff) return PowerSaverReason.screenOff;
    return PowerSaverReason.none;
  }

  void _apply() {
    final binding = WidgetsBinding.instance;
    if (binding is! PowerSavingFrameBinding) return;
    final reason = _reason;
    binding.setFrameInterval(_intervalByReason[reason] ?? Duration.zero);
    // 非前台节流档位启动自愈看门狗；回到 none 即停止（不轮询、仅节流期低频）
    if (reason == PowerSaverReason.none) {
      _stopWatchdog();
    } else {
      _startWatchdog();
    }
    // 降频协商（engine-event-push-plan §4.1）：档位变化时向引擎请求位置事件
    // 间隔——事件源头减量，Dart 侧无需在降频期高频消费 position。引擎未
    // 就绪时由 PlaybackNotifier 忽略（转码期协商被 C 侧记录，播放器启动即
    // 应用）；恢复前台时 setEngineEventInterval(50) 内部触发 get_status 对齐。
    final interval = _engineIntervalByReason[reason] ?? 50;
    if (interval != _lastEngineIntervalMs) {
      _lastEngineIntervalMs = interval;
      unawaited(
        _ref.read(playbackProvider.notifier).setEngineEventInterval(interval),
      );
    }
  }

  /// 启动/停止自愈看门狗（幂等）。
  void _startWatchdog() {
    _watchdog ??= Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_recheck());
    });
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  /// 低频复查真实窗口状态（window_manager 为权威来源）：若窗口实际可见且聚焦，
  /// 说明屏幕点亮、未最小化——修正因事件丢失而残留的失焦/熄屏档位。
  Future<void> _recheck() async {
    if (!_enabled) return;
    try {
      final minimized = await windowManager.isMinimized();
      final focused = await windowManager.isFocused();
      final visible = await windowManager.isVisible();
      final effFocused = focused && visible && !minimized;
      var changed = false;
      if (_minimized != minimized) {
        _minimized = minimized;
        changed = true;
      }
      if (_focused != effFocused) {
        _focused = effFocused;
        changed = true;
      }
      if (effFocused && _screenOff) {
        _screenOff = false; // 窗口聚焦 ⇒ 屏幕点亮
        changed = true;
      }
      if (changed) _apply();
    } catch (_) {
      // 查询失败保持现状，下个周期再试
    }
  }

  /// 强制按当前档位重新协商（新引擎会话建立后调用）：
  /// 降频期切歌时新引擎默认 50ms，需立即应用当前档位避免高频事件。
  void resync() {
    _lastEngineIntervalMs = null;
    _apply();
  }

  Future<void> dispose() async {
    windowManager.removeListener(this);
    _stopWatchdog();
    await _screenSub?.cancel();
    await _failSub?.cancel();
    await _windowSub?.cancel();
    unawaited(_power.setScreenEvents(false));
    unawaited(_window.setEvents(false));
    // 退出前释放休眠抑制（防止残留导致系统保持唤醒）
    if (_sleepActive) {
      _sleepActive = false;
      unawaited(_power.setSleepInhibit(false));
    }
    // 兜底恢复满帧
    final binding = WidgetsBinding.instance;
    if (binding is PowerSavingFrameBinding) {
      binding.setFrameInterval(Duration.zero);
    }
  }
}

/// 节能模式服务（应用级单例；随 ProviderScope 释放）。
final powerSaverProvider = Provider<PowerSaverService>((ref) {
  final caps = ref.read(platformCapabilitiesProvider);
  final svc = PowerSaverService(ref, caps.power, caps.window);
  ref.onDispose(svc.dispose);
  return svc;
});

/// 节能模式宿主：挂载即启动监听，并跟随设置实时生效。
class PowerSaverHost extends ConsumerStatefulWidget {
  const PowerSaverHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PowerSaverHost> createState() => _PowerSaverHostState();
}

class _PowerSaverHostState extends ConsumerState<PowerSaverHost> {
  @override
  void initState() {
    super.initState();
    final prefs = ref.read(appPrefsProvider);
    final svc = ref.read(powerSaverProvider);
    svc.setEnabled(prefs.powerSaver);
    svc.setSuppressSleep(prefs.suppressSleep);
    // 唤醒锁只注册在播放下：以当前播放状态起步
    svc.setPlaying(ref.read(playbackProvider).playing);
    svc.attach();
  }

  @override
  Widget build(BuildContext context) {
    // 设置页切换节能模式 / 禁用休眠后实时生效
    ref.listen(appPrefsProvider, (prev, next) {
      final svc = ref.read(powerSaverProvider);
      svc.setEnabled(next.powerSaver);
      svc.setSuppressSleep(next.suppressSleep);
    });
    // 播放 / 暂停联动唤醒锁：仅播放中且开关打开时才持有
    ref.listen(playbackProvider.select((s) => s.playing), (prev, next) {
      ref.read(powerSaverProvider).setPlaying(next);
    });
    // 新引擎会话建立（sessionId 变化）后按当前档位重新协商：
    // 降频期切歌的新引擎默认 50ms，立即应用当前档位避免高频事件
    ref.listen(playbackProvider.select((s) => s.sessionId), (prev, next) {
      if (next != null && next != prev) {
        ref.read(powerSaverProvider).resync();
      }
    });
    return widget.child;
  }
}
