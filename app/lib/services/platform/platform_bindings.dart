// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// libarchoera_platform 的 dart:ffi 绑定（apl_* C ABI）。
///
/// 本文件是 Dart 与 Zig 的唯一边界：结构体镜像 include/archoera_platform.h，
/// 事件经 NativeCallable.listener 从任意 OS 线程直达 Dart（bridge §3.6）；
/// 语义翻译（命令枚举、失败流、能力门禁）在 ffi_* 实现与工厂，本层不承载。
///
/// 加载路径复用 [NativeLibPaths]（ARCHOERA_PLATFORM_BRIDGE 环境变量 /
/// native/ 布局 / dev zig-out 候选）。
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io' show File;
import 'dart:ui' show Color;

import 'package:ffi/ffi.dart';

import '../native_lib_paths.dart';
import 'system_media.dart';

// ── 常量（对齐 archoera_platform.h）───────────────────────────────

const int aplOk = 0;
const int aplErrUnsupported = -1;
const int aplErrBackend = -2;
const int aplErrState = -3;

const int aplCapPowerInhibit = 1 << 0;
const int aplCapPowerScreenState = 1 << 1;
const int aplCapMediaSession = 1 << 2;
const int aplCapMediaSeek = 1 << 3;
const int aplCapMediaArtwork = 1 << 4;
const int aplCapWindowState = 1 << 5;
const int aplCapAppInstance = 1 << 6;
const int aplCapSystemAccent = 1 << 7;
const int aplCapSystemTheme = 1 << 8;
const int aplCapOsSession = 1 << 9;

const int aplEventMediaCommand = 1;
const int aplEventMediaSeek = 2;
const int aplEventScreenState = 3;
const int aplEventWindowState = 4;
const int aplEventBackendState = 5;
const int aplEventSystemAccent = 6;
const int aplEventSystemTheme = 7;
const int aplEventOsCapabilities = 8;
const int aplEventOsBrightness = 9;
const int aplEventOsVolume = 10;
const int aplEventOsBattery = 11;
const int aplEventOsSession = 12;
const int aplEventOsScreen = 13;
const int aplEventOsPowerKey = 14;
const int aplEventOsOutput = 15;

const int aplAbiVersion = 1;

// ── 结构体镜像 ─────────────────────────────────────────────────────

final class AplStringFfi extends Struct {
  external Pointer<Uint8> data;

  @Size()
  external int len;
}

final class AplTrackMetaFfi extends Struct {
  external AplStringFfi title;

  external AplStringFfi artist;

  external AplStringFfi album;

  @Int64()
  external int durationMs;

  external AplStringFfi artUrl;

  /// 本地封面字节（Windows 走内存流；其它平台忽略）。见 `setTrack`。
  external AplStringFfi artBytes;
}

final class AplSeekPayload extends Struct {
  @Int64()
  external int relMs;

  @Int64()
  external int absMs;
}

final class AplWindowPayload extends Struct {
  @Int32()
  external int minimized;

  @Int32()
  external int focused;
}

final class AplAccentPayload extends Struct {
  @Int32()
  external int r;

  @Int32()
  external int g;

  @Int32()
  external int b;
}

final class AplThemePayload extends Struct {
  @Int32()
  external int dark;
}

/// ArchoeraOS 会话电池事件负载（present/percent/charging）。
final class AplOsBatteryPayload extends Struct {
  @Int32()
  external int present;

  @Int32()
  external int percent;

  @Int32()
  external int charging;
}

/// ArchoeraOS 会话：主输出状态（宽/高物理像素、缩放×1000、变换、刷新率 mHz）。
final class AplOsOutputPayload extends Struct {
  @Int32()
  external int width;

  @Int32()
  external int height;

  @Int32()
  external int scaleMilli;

  @Int32()
  external int transform;

  @Int32()
  external int refreshMillihz;
}

final class AplEventPayload extends Union {
  @Int32()
  external int command;

  @Int32()
  external int active;

  external AplSeekPayload seek;

  external AplWindowPayload window;

  @Int32()
  external int backendLost;

  external AplAccentPayload accent;

  external AplThemePayload theme;

  /// ArchoeraOS 会话：capabilities 位图。
  @Int32()
  external int osCaps;

  /// ArchoeraOS 会话：brightness / volume 百分比（0-100）。
  @Int32()
  external int osValue;

  /// ArchoeraOS 会话：电池。
  external AplOsBatteryPayload osBattery;

  /// ArchoeraOS 会话：1=ready 2=shutting_down 3=suspending。
  @Int32()
  external int osSession;

  /// ArchoeraOS 会话：屏幕开关（1=亮 0=熄）。
  @Int32()
  external int osScreen;

  /// ArchoeraOS 会话：电源键（0=power 1=sleep 2=suspend）。
  @Int32()
  external int osPowerKey;

  /// ArchoeraOS 会话：主输出状态。
  external AplOsOutputPayload osOutput;
}

final class AplEventFfi extends Struct {
  @Int32()
  external int type;

  @Int32()
  external int pad;

  external AplEventPayload u;
}

// ── 函数签名 ───────────────────────────────────────────────────────

typedef _AplVersionC = Int32 Function();
typedef _AplInitC = Int32 Function();
typedef _AplShutdownC = Int32 Function();
typedef _AplCapsC = Uint32 Function();
typedef _AplPowerInhibitC = Int32 Function(Int32 on);
typedef _AplPowerScreenC = Int32 Function(Int32 on);
typedef _AplWindowEventsC = Int32 Function(Int32 on);
typedef _AplInstanceAcquireC = Int32 Function();
typedef _AplNotifyC = Int32 Function(Pointer<Utf8> title, Pointer<Utf8> body);
typedef _AplSystemAccentC =
    Int32 Function(Pointer<Int32> r, Pointer<Int32> g, Pointer<Int32> b);
typedef _AplSystemAccentSetEventsC = Int32 Function(Int32 on);
typedef _AplSystemThemeSetEventsC = Int32 Function(Int32 on);
typedef _AplOsSetEventsC = Int32 Function(Int32 on);
typedef _AplOsSetPercentC = Int32 Function(Int32 percent);
typedef _AplOsSetScreenC = Int32 Function(Int32 on);
typedef _AplOsSetModeC = Int32 Function(Int32 width, Int32 height);
typedef _AplOsVoidC = Int32 Function();
typedef _AplMediaTrackC = Int32 Function(Pointer<AplTrackMetaFfi> track);
typedef _AplMediaPlaybackC =
    Int32 Function(
      Int32 state,
      Int64 positionMs,
      Double speed,
      Double volume,
      Int32 loop,
      Int32 shuffle,
    );
typedef _AplMediaWindowC = Int32 Function(Int64 window);
typedef _SetEventCallbackC =
    Int32 Function(
      Pointer<NativeFunction<AplEventCallbackC>>,
      Pointer<Void> userData,
    );

typedef AplEventCallbackC =
    Void Function(Pointer<AplEventFfi> event, Pointer<Void> userData);

typedef _AplVersionD = int Function();
typedef _AplInitD = int Function();
typedef _AplShutdownD = int Function();
typedef _AplCapsD = int Function();
typedef _AplPowerInhibitD = int Function(int on);
typedef _AplPowerScreenD = int Function(int on);
typedef _AplWindowEventsD = int Function(int on);
typedef _AplInstanceAcquireD = int Function();
typedef _AplNotifyD = int Function(Pointer<Utf8> title, Pointer<Utf8> body);
typedef _AplSystemAccentD =
    int Function(Pointer<Int32> r, Pointer<Int32> g, Pointer<Int32> b);
typedef _AplSystemAccentSetEventsD = int Function(int on);
typedef _AplSystemThemeSetEventsD = int Function(int on);
typedef _AplOsSetEventsD = int Function(int on);
typedef _AplOsSetPercentD = int Function(int percent);
typedef _AplOsSetScreenD = int Function(int on);
typedef _AplOsSetModeD = int Function(int width, int height);
typedef _AplOsVoidD = int Function();
typedef _AplMediaTrackD = int Function(Pointer<AplTrackMetaFfi> track);
typedef _AplMediaPlaybackD =
    int Function(
      int state,
      int positionMs,
      double speed,
      double volume,
      int loop,
      int shuffle,
    );
typedef _AplMediaWindowD = int Function(int window);
typedef _SetEventCallbackD =
    int Function(
      Pointer<NativeFunction<AplEventCallbackC>>,
      Pointer<Void> userData,
    );

// ── 绑定 ───────────────────────────────────────────────────────────

/// 事件原始快照（bindings 内部从栈上指针立即取值后经流转发）。
sealed class AplNativeEvent {
  const AplNativeEvent();
}

final class AplCommandEvent extends AplNativeEvent {
  const AplCommandEvent(this.command);
  final MediaCommand command;
}

final class AplSeekEvent extends AplNativeEvent {
  const AplSeekEvent({required this.relMs, required this.absMs});
  final int relMs;
  final int absMs;
}

final class AplScreenEvent extends AplNativeEvent {
  const AplScreenEvent(this.active);
  final bool active;
}

final class AplWindowEvent extends AplNativeEvent {
  const AplWindowEvent({required this.minimized, required this.focused});
  final bool minimized;
  final bool focused;
}

final class AplBackendEvent extends AplNativeEvent {
  const AplBackendEvent(this.lost);
  final bool lost;
}

/// 系统主题色（平台推送，r/g/b 0-255）。
final class AplAccentEvent extends AplNativeEvent {
  const AplAccentEvent({required this.r, required this.g, required this.b});
  final int r;
  final int g;
  final int b;
}

/// 系统深浅色（平台推送，dark=true 深色）。
final class AplThemeEvent extends AplNativeEvent {
  const AplThemeEvent(this.dark);
  final bool dark;
}

/// ArchoeraOS 会话：能力位图（与 archoera_shell_v1 capability 位一致）。
final class AplOsCapabilitiesEvent extends AplNativeEvent {
  const AplOsCapabilitiesEvent(this.caps);
  final int caps;
}

/// ArchoeraOS 会话：亮度百分比（0-100）。
final class AplOsBrightnessEvent extends AplNativeEvent {
  const AplOsBrightnessEvent(this.percent);
  final int percent;
}

/// ArchoeraOS 会话：音量百分比（0-100，合成器镜像）。
final class AplOsVolumeEvent extends AplNativeEvent {
  const AplOsVolumeEvent(this.percent);
  final int percent;
}

/// ArchoeraOS 会话：电池状态。
final class AplOsBatteryEvent extends AplNativeEvent {
  const AplOsBatteryEvent({
    required this.present,
    required this.percent,
    required this.charging,
  });

  final bool present;
  final int percent;
  final bool charging;
}

/// ArchoeraOS 会话：会话态（1=ready 2=shutting_down 3=suspending）。
final class AplOsSessionEvent extends AplNativeEvent {
  const AplOsSessionEvent(this.state);
  final int state;
}

/// ArchoeraOS 会话：屏幕开关（DPMS）。
final class AplOsScreenEvent extends AplNativeEvent {
  const AplOsScreenEvent(this.enabled);
  final bool enabled;
}

/// ArchoeraOS 会话：电源键（0=power 1=sleep 2=suspend）。
final class AplOsPowerKeyEvent extends AplNativeEvent {
  const AplOsPowerKeyEvent(this.key);
  final int key;
}

/// ArchoeraOS 会话：主输出状态。
final class AplOsOutputEvent extends AplNativeEvent {
  const AplOsOutputEvent({
    required this.width,
    required this.height,
    required this.scaleMilli,
    required this.transform,
    required this.refreshMillihz,
  });

  final int width;
  final int height;
  final int scaleMilli;
  final int transform;
  final int refreshMillihz;
}

/// libarchoera_platform 绑定（进程级单例，[tryLoad] 失败返回 null → Noop）。
class PlatformBindings {
  PlatformBindings._(DynamicLibrary lib)
    : _version = lib.lookupFunction<_AplVersionC, _AplVersionD>(
        'apl_abi_version',
      ),
      _init = lib.lookupFunction<_AplInitC, _AplInitD>('apl_init'),
      _shutdown = lib.lookupFunction<_AplShutdownC, _AplShutdownD>(
        'apl_shutdown',
      ),
      _caps = lib.lookupFunction<_AplCapsC, _AplCapsD>('apl_capabilities'),
      _powerInhibit = lib.lookupFunction<_AplPowerInhibitC, _AplPowerInhibitD>(
        'apl_power_set_sleep_inhibit',
      ),
      _powerScreen = lib.lookupFunction<_AplPowerScreenC, _AplPowerScreenD>(
        'apl_power_set_screen_events',
      ),
      _windowEvents = lib.lookupFunction<_AplWindowEventsC, _AplWindowEventsD>(
        'apl_window_set_events',
      ),
      _instanceAcquire = lib
          .lookupFunction<_AplInstanceAcquireC, _AplInstanceAcquireD>(
            'apl_instance_acquire',
          ),
      _notify = lib.lookupFunction<_AplNotifyC, _AplNotifyD>('apl_notify'),
      _systemAccent = lib.lookupFunction<_AplSystemAccentC, _AplSystemAccentD>(
        'apl_system_accent',
      ),
      _systemAccentSetEvents = lib
          .lookupFunction<
            _AplSystemAccentSetEventsC,
            _AplSystemAccentSetEventsD
          >('apl_system_accent_set_events'),
      _systemThemeSetEvents = lib
          .lookupFunction<_AplSystemThemeSetEventsC, _AplSystemThemeSetEventsD>(
            'apl_system_theme_set_events',
          ),
      _mediaTrack = lib.lookupFunction<_AplMediaTrackC, _AplMediaTrackD>(
        'apl_media_set_track',
      ),
      _mediaPlayback = lib
          .lookupFunction<_AplMediaPlaybackC, _AplMediaPlaybackD>(
            'apl_media_set_playback',
          ),
      _mediaWindow = lib.lookupFunction<_AplMediaWindowC, _AplMediaWindowD>(
        'apl_media_set_window',
      ),
      // ArchoeraOS 会话符号：可选（旧版桥接缺失时应整体降级为 Noop，而非拖垮桥接）
      _osSetEvents = _try(
        () => lib.lookupFunction<_AplOsSetEventsC, _AplOsSetEventsD>(
          'apl_os_set_events',
        ),
      ),
      _osSetBrightness = _try(
        () => lib.lookupFunction<_AplOsSetPercentC, _AplOsSetPercentD>(
          'apl_os_set_brightness',
        ),
      ),
      _osSetVolume = _try(
        () => lib.lookupFunction<_AplOsSetPercentC, _AplOsSetPercentD>(
          'apl_os_set_volume',
        ),
      ),
      _osSetScreen = _try(
        () => lib.lookupFunction<_AplOsSetScreenC, _AplOsSetScreenD>(
          'apl_os_set_screen_enabled',
        ),
      ),
      _osPowerOff = _try(
        () => lib.lookupFunction<_AplOsVoidC, _AplOsVoidD>('apl_os_power_off'),
      ),
      _osReboot = _try(
        () => lib.lookupFunction<_AplOsVoidC, _AplOsVoidD>('apl_os_reboot'),
      ),
      _osSuspend = _try(
        () => lib.lookupFunction<_AplOsVoidC, _AplOsVoidD>('apl_os_suspend'),
      ),
      _osHibernate = _try(
        () => lib.lookupFunction<_AplOsVoidC, _AplOsVoidD>('apl_os_hibernate'),
      ),
      _osSetOutputScale = _try(
        () => lib.lookupFunction<_AplOsSetPercentC, _AplOsSetPercentD>(
          'apl_os_set_output_scale',
        ),
      ),
      _osSetOutputMode = _try(
        () => lib.lookupFunction<_AplOsSetModeC, _AplOsSetModeD>(
          'apl_os_set_output_mode',
        ),
      ),
      _osSetOutputTransform = _try(
        () => lib.lookupFunction<_AplOsSetPercentC, _AplOsSetPercentD>(
          'apl_os_set_output_transform',
        ),
      ),
      _setCallback = lib.lookupFunction<_SetEventCallbackC, _SetEventCallbackD>(
        'apl_set_event_callback',
      ) {
    // 事件回调：listener 可从任意 OS 线程触发，事件按到达序进入 Dart 端口
    _eventCallable = NativeCallable<AplEventCallbackC>.listener(_onNativeEvent);
    _setCallback(_eventCallable.nativeFunction, nullptr);
  }

  /// 查询可选符号，缺失（旧版桥接）返回 null 以优雅降级。
  static T? _try<T>(T Function() lookup) {
    try {
      return lookup();
    } catch (_) {
      return null;
    }
  }

  static PlatformBindings? _instance;

  late final NativeCallable<AplEventCallbackC> _eventCallable;

  bool _disposed = false;

  final _AplVersionD _version;
  final _AplInitD _init;
  final _AplShutdownD _shutdown;
  final _AplCapsD _caps;
  final _AplPowerInhibitD _powerInhibit;
  final _AplPowerScreenD _powerScreen;
  final _AplWindowEventsD _windowEvents;
  final _AplInstanceAcquireD _instanceAcquire;
  final _AplNotifyD _notify;
  final _AplSystemAccentD _systemAccent;
  final _AplSystemAccentSetEventsD _systemAccentSetEvents;
  final _AplSystemThemeSetEventsD _systemThemeSetEvents;
  final _AplMediaTrackD _mediaTrack;
  final _AplMediaPlaybackD _mediaPlayback;
  final _AplMediaWindowD _mediaWindow;
  final _SetEventCallbackD _setCallback;
  final _AplOsSetEventsD? _osSetEvents;
  final _AplOsSetPercentD? _osSetBrightness;
  final _AplOsSetPercentD? _osSetVolume;
  final _AplOsSetScreenD? _osSetScreen;
  final _AplOsVoidD? _osPowerOff;
  final _AplOsVoidD? _osReboot;
  final _AplOsVoidD? _osSuspend;
  final _AplOsVoidD? _osHibernate;
  final _AplOsSetPercentD? _osSetOutputScale;
  final _AplOsSetModeD? _osSetOutputMode;
  final _AplOsSetPercentD? _osSetOutputTransform;

  // 四类事件广播流（ffi_* 实现订阅转译）
  final _commandCtrl = StreamController<MediaCommandEvent>.broadcast();
  final _seekCtrl = StreamController<AplSeekEvent>.broadcast();
  final _screenCtrl = StreamController<AplScreenEvent>.broadcast();
  final _windowCtrl = StreamController<AplWindowEvent>.broadcast();
  final _backendCtrl = StreamController<AplBackendEvent>.broadcast();
  final _accentCtrl = StreamController<AplAccentEvent>.broadcast();
  final _themeCtrl = StreamController<AplThemeEvent>.broadcast();
  final _osCapsCtrl = StreamController<AplOsCapabilitiesEvent>.broadcast();
  final _osBrightnessCtrl = StreamController<AplOsBrightnessEvent>.broadcast();
  final _osVolumeCtrl = StreamController<AplOsVolumeEvent>.broadcast();
  final _osBatteryCtrl = StreamController<AplOsBatteryEvent>.broadcast();
  final _osSessionCtrl = StreamController<AplOsSessionEvent>.broadcast();
  final _osScreenCtrl = StreamController<AplOsScreenEvent>.broadcast();
  final _osPowerKeyCtrl = StreamController<AplOsPowerKeyEvent>.broadcast();
  final _osOutputCtrl = StreamController<AplOsOutputEvent>.broadcast();

  /// ArchoeraOS 会话函数是否可用（桥接提供且非旧版）。
  bool get osSessionSymbolsAvailable => _osSetEvents != null;

  // ── ArchoeraOS 会话正向调用（符号缺失返回 UNSUPPORTED）──
  int osSetEvents(bool on) =>
      _osSetEvents?.call(on ? 1 : 0) ?? aplErrUnsupported;
  int osSetBrightness(int percent) =>
      _osSetBrightness?.call(percent) ?? aplErrUnsupported;
  int osSetVolume(int percent) =>
      _osSetVolume?.call(percent) ?? aplErrUnsupported;
  int osSetScreenEnabled(bool on) =>
      _osSetScreen?.call(on ? 1 : 0) ?? aplErrUnsupported;
  int osPowerOff() => _osPowerOff?.call() ?? aplErrUnsupported;
  int osReboot() => _osReboot?.call() ?? aplErrUnsupported;
  int osSuspend() => _osSuspend?.call() ?? aplErrUnsupported;
  int osHibernate() => _osHibernate?.call() ?? aplErrUnsupported;
  int osSetOutputScale(int scaleMilli) =>
      _osSetOutputScale?.call(scaleMilli) ?? aplErrUnsupported;
  int osSetOutputMode(int width, int height) =>
      _osSetOutputMode?.call(width, height) ?? aplErrUnsupported;
  int osSetOutputTransform(int transform) =>
      _osSetOutputTransform?.call(transform) ?? aplErrUnsupported;

  /// 单实例仲裁：1=首实例；0=已有实例；<0=错误。
  int acquireInstance() => _instanceAcquire();

  /// 订阅系统主题色变更事件（变更时 accentEvents 推事件）。
  int setAccentEvents(bool on) => _systemAccentSetEvents(on ? 1 : 0);

  /// 订阅系统深浅色（订阅即收当前值，之后收变化）。
  int setThemeEvents(bool on) => _systemThemeSetEvents(on ? 1 : 0);

  /// 系统主题色（DE accent）；不可得返回 null。
  Color? systemAccent() {
    final r = calloc<Int32>();
    final g = calloc<Int32>();
    final b = calloc<Int32>();
    try {
      if (_systemAccent(r, g, b) != aplOk) return null;
      return Color.fromARGB(255, r.value, g.value, b.value);
    } finally {
      calloc.free(r);
      calloc.free(g);
      calloc.free(b);
    }
  }

  /// 系统提示（UTF-8）。用于“已有实例”等无 UI 框架场景。
  int notify(String title, String body) {
    final t = title.toNativeUtf8();
    final b = body.toNativeUtf8();
    try {
      return _notify(t, b);
    } finally {
      malloc.free(t);
      malloc.free(b);
    }
  }

  /// 尝试加载并 init；任何一步失败返回 null（Dart 侧走 Noop）。
  static PlatformBindings? tryLoad() {
    if (_instance != null) return _instance;
    final path = NativeLibPaths.resolve(NativeModule.platformBridge);
    if (path == null) return null;
    try {
      final lib = DynamicLibrary.open(path);
      final b = PlatformBindings._(lib);
      if (b._version() != aplAbiVersion) return null; // 契约版本不符 → Noop
      if (b._init() != aplOk) return null;
      _instance = b;
      return b;
    } catch (_) {
      return null;
    }
  }

  // ── 事件流 ──

  Stream<MediaCommandEvent> get commandEvents => _commandCtrl.stream;
  Stream<AplSeekEvent> get seekEvents => _seekCtrl.stream;
  Stream<AplScreenEvent> get screenEvents => _screenCtrl.stream;
  Stream<AplWindowEvent> get windowEvents => _windowCtrl.stream;
  Stream<AplBackendEvent> get backendEvents => _backendCtrl.stream;
  Stream<AplAccentEvent> get accentEvents => _accentCtrl.stream;
  Stream<AplThemeEvent> get themeEvents => _themeCtrl.stream;
  Stream<AplOsCapabilitiesEvent> get osCapabilitiesEvents => _osCapsCtrl.stream;
  Stream<AplOsBrightnessEvent> get osBrightnessEvents =>
      _osBrightnessCtrl.stream;
  Stream<AplOsVolumeEvent> get osVolumeEvents => _osVolumeCtrl.stream;
  Stream<AplOsBatteryEvent> get osBatteryEvents => _osBatteryCtrl.stream;
  Stream<AplOsSessionEvent> get osSessionEvents => _osSessionCtrl.stream;
  Stream<AplOsScreenEvent> get osScreenEvents => _osScreenCtrl.stream;
  Stream<AplOsPowerKeyEvent> get osPowerKeyEvents => _osPowerKeyCtrl.stream;
  Stream<AplOsOutputEvent> get osOutputEvents => _osOutputCtrl.stream;

  /// 栈上指针仅在回调期间有效——同步取值后立即投递。
  static void _onNativeEvent(
    Pointer<AplEventFfi> event,
    Pointer<Void> userData,
  ) {
    final b = _instance;
    if (b == null || event == nullptr) return;
    final ref = event.ref;
    switch (ref.type) {
      case aplEventMediaCommand:
        b._commandCtrl.add(
          MediaCommandEvent(_commandFromNative(ref.u.command)),
        );
      case aplEventMediaSeek:
        b._seekCtrl.add(
          AplSeekEvent(relMs: ref.u.seek.relMs, absMs: ref.u.seek.absMs),
        );
      case aplEventScreenState:
        b._screenCtrl.add(AplScreenEvent(ref.u.active != 0));
      case aplEventWindowState:
        b._windowCtrl.add(
          AplWindowEvent(
            minimized: ref.u.window.minimized != 0,
            focused: ref.u.window.focused != 0,
          ),
        );
      case aplEventBackendState:
        b._backendCtrl.add(AplBackendEvent(ref.u.backendLost != 0));
      case aplEventSystemAccent:
        b._accentCtrl.add(
          AplAccentEvent(
            r: ref.u.accent.r,
            g: ref.u.accent.g,
            b: ref.u.accent.b,
          ),
        );
      case aplEventSystemTheme:
        b._themeCtrl.add(AplThemeEvent(ref.u.theme.dark != 0));
      case aplEventOsCapabilities:
        b._osCapsCtrl.add(AplOsCapabilitiesEvent(ref.u.osCaps));
      case aplEventOsBrightness:
        b._osBrightnessCtrl.add(AplOsBrightnessEvent(ref.u.osValue));
      case aplEventOsVolume:
        b._osVolumeCtrl.add(AplOsVolumeEvent(ref.u.osValue));
      case aplEventOsBattery:
        b._osBatteryCtrl.add(
          AplOsBatteryEvent(
            present: ref.u.osBattery.present != 0,
            percent: ref.u.osBattery.percent,
            charging: ref.u.osBattery.charging != 0,
          ),
        );
      case aplEventOsSession:
        b._osSessionCtrl.add(AplOsSessionEvent(ref.u.osSession));
      case aplEventOsScreen:
        b._osScreenCtrl.add(AplOsScreenEvent(ref.u.osScreen != 0));
      case aplEventOsOutput:
        b._osOutputCtrl.add(
          AplOsOutputEvent(
            width: ref.u.osOutput.width,
            height: ref.u.osOutput.height,
            scaleMilli: ref.u.osOutput.scaleMilli,
            transform: ref.u.osOutput.transform,
            refreshMillihz: ref.u.osOutput.refreshMillihz,
          ),
        );
      case aplEventOsPowerKey:
        b._osPowerKeyCtrl.add(AplOsPowerKeyEvent(ref.u.osPowerKey));
    }
  }

  static MediaCommand _commandFromNative(int raw) => switch (raw) {
    0 => MediaCommand.play,
    1 => MediaCommand.pause,
    2 => MediaCommand.toggle,
    3 => MediaCommand.stop,
    4 => MediaCommand.next,
    5 => MediaCommand.previous,
    6 => MediaCommand.volumeUp,
    7 => MediaCommand.volumeDown,
    8 => MediaCommand.volumeMute,
    _ => MediaCommand.previous,
  };

  // ── 正向调用 ──

  int capabilities() => _caps();

  int setSleepInhibit(bool on) => _powerInhibit(on ? 1 : 0);

  int setScreenEvents(bool on) => _powerScreen(on ? 1 : 0);

  int setWindowEvents(bool on) => _windowEvents(on ? 1 : 0);

  int setPlayback(
    int state,
    int positionMs,
    double speed,
    double volume,
    int loop,
    int shuffle,
  ) => _mediaPlayback(state, positionMs, speed, volume, loop, shuffle);

  int setWindow(int window) => _mediaWindow(window);

  /// 拷贝曲目元数据到原生内存发起调用；调用同步返回后立即释放。
  int setTrack(
    String? title,
    String? artist,
    String? album,
    int? durationMs,
    String? artUrl,
  ) {
    if (title == null) return _mediaTrack(nullptr);
    final meta = calloc<AplTrackMetaFfi>();
    final pointers = <Pointer<Uint8>>[];
    try {
      _fillString(meta.ref.title, title, pointers);
      _fillString(meta.ref.artist, artist, pointers);
      _fillString(meta.ref.album, album, pointers);
      meta.ref.durationMs = durationMs ?? -1;
      _fillString(meta.ref.artUrl, artUrl, pointers);
      _fillArtBytes(meta.ref.artBytes, artUrl, pointers);
      return _mediaTrack(meta);
    } finally {
      for (final p in pointers) {
        malloc.free(p);
      }
      calloc.free(meta);
    }
  }

  /// 经嵌套 struct 视图写入字段（不新建 Struct；缓冲 malloc 分配，调用后释放）。
  void _fillString(AplStringFfi view, String? s, List<Pointer<Uint8>> sink) {
    if (s == null || s.isEmpty) {
      view.data = nullptr;
      view.len = 0;
      return;
    }
    // toNativeUtf8：NUL 结尾 UTF-8；length = 字节数（不含 NUL）
    final native = s.toNativeUtf8(allocator: malloc);
    sink.add(native.cast<Uint8>());
    view.data = native.cast<Uint8>();
    view.len = native.length;
  }

  /// 本地封面（file:// 或本地路径）→ 读文件字节填入 [view]（供原生内存流）；
  /// http(s) / 空 / 读取失败则置空（原生按 artUrl 处理）。
  void _fillArtBytes(
    AplStringFfi view,
    String? artUrl,
    List<Pointer<Uint8>> sink,
  ) {
    view.data = nullptr;
    view.len = 0;
    if (artUrl == null || artUrl.isEmpty) return;
    if (artUrl.startsWith('http://') || artUrl.startsWith('https://')) return;
    final path = artUrl.startsWith('file://') ? artUrl.substring(7) : artUrl;
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      final bytes = f.readAsBytesSync();
      if (bytes.isEmpty) return;
      final buf = malloc.allocate<Uint8>(bytes.length);
      buf.asTypedList(bytes.length).setAll(0, bytes);
      sink.add(buf);
      view.data = buf;
      view.len = bytes.length;
    } catch (_) {
      // 读取失败：交给原生按 artUrl 处理
    }
  }

  /// 释放事件回调 + 关闭原生后端（停 inhibit 线程 / 关单实例互斥体 /
  /// SMTC deinit 释放 WinRT 对象）；幂等。须在进程退出前调用（COM 仍初始化）。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _shutdown();
    _setCallback(nullptr, nullptr);
    _eventCallable.close();
    _commandCtrl.close();
    _seekCtrl.close();
    _screenCtrl.close();
    _windowCtrl.close();
    _backendCtrl.close();
    _accentCtrl.close();
    _themeCtrl.close();
    _osCapsCtrl.close();
    _osBrightnessCtrl.close();
    _osVolumeCtrl.close();
    _osBatteryCtrl.close();
    _osSessionCtrl.close();
    _osScreenCtrl.close();
    _osPowerKeyCtrl.close();
    _instance = null;
  }
}
