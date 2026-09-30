// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../apis/netease/core/cache.dart' show nmCacheClear;
import '../../apis/runtime.dart' show getRuntime;
import '../../l10n/l10n.dart';
import '../../stores/app_prefs.dart';
import '../../stores/daily_shelf_provider.dart' show dailyShelfProvider;
import '../../stores/lyrics_provider.dart' show currentLyricsProvider;
import '../../stores/spotlight_provider.dart' show spotlightProvider;
import '../../theme/cover_color.dart' show coverColorProvider;
import '../log/log.dart';
import '../scanner/library_store.dart' show libraryStoreProvider;
import '../streaming/streaming_provider.dart' show streamingProvider;
import '../platform/platform_capabilities.dart';
import '../platform/platform_failure.dart';
import '../platform/system_power.dart';
import '../platform/system_window.dart';
import '../playback/playback_notifier.dart';
import '../../widgets/common/toast.dart';
import 'frame_governor.dart';

/// 节能原因（决定目标帧率上限 / 是否停帧）。
enum PowerSaverReason {
  /// 前台正常渲染（不限制帧率）。
  none,

  /// 窗口最小化 / 隐藏到托盘：**直接停止渲染**（0 帧）。
  minimized,

  /// 窗口失焦（同桌面其他应用被聚焦）：1 FPS。
  unfocused,

  /// 屏幕关闭 / 锁屏（Linux D-Bus `ActiveChanged` 信号）：1 FPS。
  screenOff,
}

/// 非停帧档位的目标最小帧间隔（最小化不在此表：直接停帧）。
const Map<PowerSaverReason, Duration> _intervalByReason = {
  PowerSaverReason.unfocused: Duration(seconds: 1), // 1 FPS
  PowerSaverReason.screenOff: Duration(seconds: 1), // 1 FPS
};

/// 节能档位 → 渲染策略：
/// - 最小化 / 隐藏到托盘 → [stopRendering] = true（**直接停止渲染**，0 帧）；
/// - 其余档位 → 按 [interval] 降频（失焦/熄屏 1 FPS，前台 zero=满帧）。
///
/// 纯函数（无副作用），便于单测；实际应用在 `PowerSaverService._apply`。
({bool stopRendering, Duration interval}) powerSaverRenderPolicy(
  PowerSaverReason reason,
) {
  if (reason == PowerSaverReason.minimized) {
    return (stopRendering: true, interval: Duration.zero);
  }
  return (
    stopRendering: false,
    interval: _intervalByReason[reason] ?? Duration.zero,
  );
}

/// 全局节能模式服务。
///
/// - 窗口最小化 / 隐藏到托盘时**直接停止渲染**（0 帧）；失焦 / 熄屏时
///   降帧到 1 FPS；均通过 [PowerSavingFrameBinding] 生效；
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

  /// 进入后台后延迟执行「释放/卸载」的阈值。
  ///
  /// 关键：**不**在每次 hide/minimize 立即卸载界面——反复「隐藏→显示」会不断
  /// 卸载/重建路由子树，churn 掉渲染资源（实测每次 hide/show 进程 RSS/原生堆
  /// 增长数 MB，Windows 上表现为“内存泄漏”）。改为持续后台达阈值才释放一次；
  /// 快速切换（< 阈值）完全不做释放，避免 churn。取较大值（30s）：只有真正
  /// 「长时间挂后台」才释放，最大化避免表面/图层重建。
  static const Duration _unloadDelay = Duration(seconds: 30);
  Timer? _unloadTimer;

  /// 是否已执行过后台释放/卸载（恢复时据此复位标志与重新挂载）。
  bool _unloadApplied = false;

  /// 强迫症「最小化时卸载全部内存状态」（设置项，默认关）。
  bool _unloadAll = false;

  /// 同步设置「最小化时卸载全部内存状态」；开启且当前已在后台 → 立即卸载。
  void setUnloadAll(bool value) {
    if (_unloadAll == value) return;
    _unloadAll = value;
    // 若在后台期间开启，按当前档位重新评估（会走一次延迟释放）。
    _apply();
  }

  /// 丢弃**可重建的页面数据 provider**（音乐库窗口 / 首页聚光 / 每日推荐 /
  /// 流媒体库 / 当前歌词）。
  ///
  /// 只在「后台卸载帧」跑完之后调用：此时根级卸载门已把整个路由子树（含这些
  /// provider 的监听者）卸下，invalidate 不会立即触发网络重取——重取发生在
  /// 恢复前台、页面重新挂载时。播放/认证/偏好/平台能力一律不动。
  void _dropRebuildableState() {
    if (!_unloadAll) return;
    try {
      _ref.invalidate(libraryStoreProvider);
      _ref.invalidate(spotlightProvider);
      _ref.invalidate(dailyShelfProvider);
      _ref.invalidate(currentLyricsProvider);
      _ref.invalidate(streamingProvider);
    } catch (_) {}
    Log.i('power', '后台：已卸载页面数据（库 / 聚光 / 每日推荐 / 流媒体 / 歌词）');
  }

  /// 进入后台时释放可重建的缓存（图片 / 歌词三件套 / 封面色 / 接口响应），
  /// 减少后台常驻；恢复前台后按需重新加载。纯安全清理，不影响播放。
  void _releaseCaches() {
    try {
      final cache = PaintingBinding.instance.imageCache;
      cache.clear();
      cache.clearLiveImages();
    } catch (_) {}
    try {
      final rt = getRuntime();
      rt.lyricCache.clear();
      rt.lyricMatchCache.clear();
      rt.lyricTtmlCache.clear();
    } catch (_) {}
    try {
      _ref.read(coverColorProvider.notifier).clearCache();
    } catch (_) {}
    try {
      nmCacheClear();
    } catch (_) {}
    Log.i('power', '后台：已释放图片/歌词/取色/接口缓存');
  }

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
      Log.w('power', '桥接窗口状态不可用（回退 window_manager）');
      return;
    }
    _windowSub = _window.state.listen((s) {
      // **只置位、不清除** minimized：部分合成器把「GTK hide 到托盘」报告为
      // minimized=false，若在此覆盖会把后台态闪回前台，导致后台释放/停帧被
      // 立刻取消（并让「持续后台才释放」的判定永不成立）。清除交给显式的
      // show/restore 事件（onWindowEvent('show') / onWindowRestore）。
      if (s.minimized) _minimized = true;
      _focused = s.focused;
      // 重新聚焦窗口 ⇒ **强制重建**：屏幕必然点亮/未锁屏。修正解锁后丢失的
      // 熄屏复位（否则残留 screenOff → 永久 1 FPS，重启才恢复）。
      if (s.focused && !s.minimized) _screenOff = false;
      _apply();
    });
  }

  /// 经平台能力外观订阅熄屏状态（原生桥接事件驱动，非轮询）。
  /// 订阅失败 / 能力缺失仅 debug 回落（后台优化类，不打断用户）。
  Future<void> _attachScreenWatcher() async {
    if (_screenSub != null) return;
    final ok = await _power.setScreenEvents(true);
    if (!ok) {
      Log.w('power', '熄屏状态订阅不可用（忽略熄屏场景）');
    }
    _screenSub = _power.screenState.listen((active) {
      _screenOff = active;
      _apply();
    });
    _failSub = _power.failures.listen((f) {
      Log.e('power', '平台能力失败: $f');
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
      Log.e('power', '禁用系统休眠切换失败');
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
    final inBg = _minimized || _screenOff;

    if (!inBg) {
      // 恢复前台：取消待执行的释放；若已卸载则复位标志（卸载门重新挂载路由），
      // 立即恢复出帧/满帧。
      _unloadTimer?.cancel();
      _unloadTimer = null;
      if (_unloadApplied) {
        _unloadApplied = false;
        _ref.read(appInBackgroundProvider.notifier).set(false);
      }
      _applyRenderPolicy(binding);
      return;
    }

    // 后台：立即停帧/降频（廉价、必要；无 churn）。
    _applyRenderPolicy(binding);

    // 仅在「持续后台」达到阈值后释放一次；快速 hide/show 不做任何释放。
    if (!_unloadApplied && _unloadTimer == null) {
      _unloadTimer = Timer(_unloadDelay, () {
        _unloadTimer = null;
        _doUnload();
      });
    }
  }

  /// 持续后台达阈值后的**一次性同步释放**。不依赖系统/帧：
  ///
  /// 隐藏/最小化时引擎可能**不出帧**，`addPostFrameCallback` 永不执行（实测：
  /// timer 触发了却没有任何释放）——所以缓存/页面数据的释放必须**同步**做掉，
  /// 唯一需要重建的部分（路由子树卸载）交给下一帧（或恢复前台的首帧）由
  /// `BackgroundUnloadGate` 依据 [appInBackgroundProvider] 自行处理。
  void _doUnload() {
    if (!(_minimized || _screenOff)) return; // 已恢复
    // ① 同步释放可重建的缓存与页面数据（不需要帧，后台立刻见效）。
    _releaseCaches();
    _dropRebuildableState();
    // ② UI 子树卸载：**仅强迫症档显式开启时**才做。默认**不卸载 UI**——
    //    实测卸载/重建路由子树会 churn 渲染资源（表面/图层/驱动缓存只涨不缩），
    //    且隐藏期不出帧时「卸载」在恢复首帧才发生，收益远小于代价。默认只做
    //    ① 的同步数据/缓存释放（安全、无 GPU churn）。
    final prefs = _ref.read(appPrefsProvider);
    if (prefs.unloadAllMemory) {
      _unloadApplied = true;
      _ref.read(appInBackgroundProvider.notifier).set(true);
    }
  }

  /// 应用渲染策略（最小化/托盘 → 停帧；失焦/熄屏 → 降频）+ 引擎事件降频协商。
  void _applyRenderPolicy(WidgetsBinding binding) {
    if (binding is! PowerSavingFrameBinding) return;
    final reason = _reason;
    final policy = powerSaverRenderPolicy(reason);
    binding.setRenderingEnabled(!policy.stopRendering);
    if (!policy.stopRendering) {
      binding.setFrameInterval(policy.interval);
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

  /// 强制按当前档位重新协商（新引擎会话建立后调用）：
  /// 降频期切歌时新引擎默认 50ms，需立即应用当前档位避免高频事件。
  void resync() {
    _lastEngineIntervalMs = null;
    _apply();
  }

  Future<void> dispose() async {
    _unloadTimer?.cancel();
    _unloadTimer = null;
    windowManager.removeListener(this);
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
    // 兜底恢复渲染（解除停帧）与满帧
    final binding = WidgetsBinding.instance;
    if (binding is PowerSavingFrameBinding) {
      binding.setRenderingEnabled(true);
      binding.setFrameInterval(Duration.zero);
    }
  }
}

/// 应用是否处于「不可见后台」（最小化 / 托盘隐藏 / 熄屏）。
///
/// 由 [PowerSaverService] 更新，驱动 `app.dart` 的 `BackgroundUnloadGate`：
/// 仅当强迫症档 `unloadAllMemory` 开启且为 true 时，整个路由子树被卸为纯色
/// 占位（释放页面/图片内存），恢复后重建。默认档只做同步数据/缓存释放，不卸载 UI。
class AppInBackgroundNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// 更新后台标志（值不变不通知）。
  void set(bool value) {
    if (state != value) state = value;
  }
}

final appInBackgroundProvider =
    NotifierProvider<AppInBackgroundNotifier, bool>(
      AppInBackgroundNotifier.new,
    );

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
    svc.setUnloadAll(prefs.unloadAllMemory);
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
      svc.setUnloadAll(next.unloadAllMemory);
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
