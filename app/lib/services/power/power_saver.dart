import 'dart:async';
import 'dart:io' show Platform;

import 'package:dbus/dbus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../../stores/app_prefs.dart';
import '../playback/playback_notifier.dart';
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
/// - 「禁用系统休眠」仅**在媒体播放中**通过 wakelock_plus 保持系统唤醒，
///   暂停 / 停止时立即释放，后台播放不中断。
///
/// 全程事件驱动：window_manager 窗口事件 + D-Bus 信号订阅 + Timer 帧合并，
/// 不使用轮询。窗口隐藏 / 屏幕关闭时若引擎已内建停帧（GTK 无 vsync、
/// 显示器关闭等），以引擎内建节能为准，本服务设置的帧率上限只是兜底。
class PowerSaverService with WindowListener {
  PowerSaverService();

  /// 节能模式总开关（设置持久化，默认开）。
  bool _enabled = true;

  bool _minimized = false;
  bool _focused = true;
  bool _screenOff = false;

  /// 应用内媒体是否正在播放（仅播放中才允许注册唤醒锁）。
  bool _playing = false;

  /// 「禁用系统休眠」设置（默认关，持久化）。
  bool _suppressSleep = false;

  /// 唤醒锁当前实际持有状态（避免对插件重复调用）。
  bool _sleepActive = false;

  StreamSubscription<DBusSignal>? _screenSub;
  DBusClient? _dbusClient;
  bool _dbusAttached = false;

  static const Map<PowerSaverReason, Duration> _intervalByReason = {
    PowerSaverReason.minimized: Duration(milliseconds: 200), // 5 FPS
    PowerSaverReason.unfocused: Duration(seconds: 1), // 1 FPS
    PowerSaverReason.screenOff: Duration(seconds: 1), // 1 FPS
  };

  /// 开始监听窗口状态（并异步探测 Linux 屏幕状态信号）。
  void attach() {
    windowManager.addListener(this);
    unawaited(_attachScreenWatcher());
  }

  /// Linux：订阅桌面环境 screensaver 服务的 `ActiveChanged` 信号
  /// （事件驱动，非轮询）。服务不可用时静默忽略该场景。
  Future<void> _attachScreenWatcher() async {
    if (!Platform.isLinux || _dbusAttached) return;
    _dbusAttached = true;
    try {
      // DBusClient.session() 为同步工厂（惰性连接），后续调用即发起连接
      final client = DBusClient.session();
      final name = await _pickScreensaverService(client);
      if (name == null) {
        await client.close();
        return;
      }
      final path = name == 'org.gnome.ScreenSaver'
          ? DBusObjectPath('/org/gnome/ScreenSaver')
          : DBusObjectPath('/org/freedesktop/ScreenSaver');
      final obj = DBusRemoteObject(client, name: name, path: path);
      final stream = DBusRemoteObjectSignalStream(
        object: obj,
        interface: name,
        name: 'ActiveChanged',
      );
      _dbusClient = client;
      _screenSub = stream.listen(
        (signal) {
          final active =
              signal.values.isNotEmpty && signal.values[0].asBoolean();
          _screenOff = active;
          _apply();
        },
        onError: (Object e) {
          debugPrint('[power] 屏幕状态信号异常: $e');
        },
      );
    } catch (e) {
      debugPrint('[power] 屏幕状态监听不可用（忽略熄屏场景）: $e');
      await _dbusClient?.close();
      _dbusClient = null;
    }
  }

  Future<String?> _pickScreensaverService(DBusClient client) async {
    for (final name in [
      'org.freedesktop.ScreenSaver',
      'org.gnome.ScreenSaver',
    ]) {
      try {
        if (await client.nameHasOwner(name)) return name;
      } catch (_) {
        // 探测失败尝试下一个
      }
    }
    return null;
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

  /// 按「设置 + 播放中」双条件决定唤醒锁；状态未变化时不重复调用插件。
  ///
  /// wakelock_plus 跨平台实现：Linux 走 XDG Desktop Portal（Inhibit）、
  /// Windows/macOS 用原生 API、Android/iOS/Web 各走平台通道；平台不可用
  /// （如无 portal 的环境）时 try-catch 静默降级并回滚状态，不影响播放。
  Future<void> _applySleep() async {
    final want = _suppressSleep && _playing;
    if (want == _sleepActive) return;
    _sleepActive = want;
    try {
      await WakelockPlus.toggle(enable: want);
    } catch (e) {
      _sleepActive = !want;
      debugPrint('[power] 禁用系统休眠切换失败: $e');
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
    _apply();
  }

  @override
  void onWindowFocus() {
    _focused = true;
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
    binding.setFrameInterval(_intervalByReason[_reason] ?? Duration.zero);
  }

  Future<void> dispose() async {
    windowManager.removeListener(this);
    await _screenSub?.cancel();
    await _dbusClient?.close();
    _dbusClient = null;
    // 退出前释放唤醒锁（防止残留导致系统保持唤醒）
    if (_sleepActive) {
      _sleepActive = false;
      try {
        await WakelockPlus.disable();
      } catch (_) {
        // 平台不可用时忽略
      }
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
  final svc = PowerSaverService();
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
    return widget.child;
  }
}
