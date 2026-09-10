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

const int aplEventMediaCommand = 1;
const int aplEventMediaSeek = 2;
const int aplEventScreenState = 3;
const int aplEventWindowState = 4;
const int aplEventBackendState = 5;

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

final class AplEventPayload extends Union {
  @Int32()
  external int command;

  @Int32()
  external int active;

  external AplSeekPayload seek;

  external AplWindowPayload window;

  @Int32()
  external int backendLost;
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
typedef _AplCapsC = Uint32 Function();
typedef _AplPowerInhibitC = Int32 Function(Int32 on);
typedef _AplPowerScreenC = Int32 Function(Int32 on);
typedef _AplWindowEventsC = Int32 Function(Int32 on);
typedef _AplInstanceAcquireC = Int32 Function();
typedef _AplNotifyC = Int32 Function(Pointer<Utf8> title, Pointer<Utf8> body);
typedef _AplMediaTrackC = Int32 Function(Pointer<AplTrackMetaFfi> track);
typedef _AplMediaPlaybackC = Int32 Function(
    Int32 state, Int64 positionMs, Double speed, Double volume, Int32 loop, Int32 shuffle);
typedef _AplMediaWindowC = Int32 Function(Int64 window);
typedef _SetEventCallbackC = Int32 Function(
    Pointer<NativeFunction<AplEventCallbackC>>, Pointer<Void> userData);

typedef AplEventCallbackC = Void Function(
    Pointer<AplEventFfi> event, Pointer<Void> userData);

typedef _AplVersionD = int Function();
typedef _AplInitD = int Function();
typedef _AplCapsD = int Function();
typedef _AplPowerInhibitD = int Function(int on);
typedef _AplPowerScreenD = int Function(int on);
typedef _AplWindowEventsD = int Function(int on);
typedef _AplInstanceAcquireD = int Function();
typedef _AplNotifyD = int Function(Pointer<Utf8> title, Pointer<Utf8> body);
typedef _AplMediaTrackD = int Function(Pointer<AplTrackMetaFfi> track);
typedef _AplMediaPlaybackD = int Function(
    int state, int positionMs, double speed, double volume, int loop, int shuffle);
typedef _AplMediaWindowD = int Function(int window);
typedef _SetEventCallbackD = int Function(
    Pointer<NativeFunction<AplEventCallbackC>>, Pointer<Void> userData);

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

/// libarchoera_platform 绑定（进程级单例，[tryLoad] 失败返回 null → Noop）。
class PlatformBindings {
  PlatformBindings._(DynamicLibrary lib)
      : _version = lib.lookupFunction<_AplVersionC, _AplVersionD>('apl_abi_version'),
        _init = lib.lookupFunction<_AplInitC, _AplInitD>('apl_init'),
        _caps = lib.lookupFunction<_AplCapsC, _AplCapsD>('apl_capabilities'),
        _powerInhibit =
            lib.lookupFunction<_AplPowerInhibitC, _AplPowerInhibitD>('apl_power_set_sleep_inhibit'),
        _powerScreen =
            lib.lookupFunction<_AplPowerScreenC, _AplPowerScreenD>('apl_power_set_screen_events'),
        _windowEvents =
            lib.lookupFunction<_AplWindowEventsC, _AplWindowEventsD>('apl_window_set_events'),
        _instanceAcquire =
            lib.lookupFunction<_AplInstanceAcquireC, _AplInstanceAcquireD>('apl_instance_acquire'),
        _notify = lib.lookupFunction<_AplNotifyC, _AplNotifyD>('apl_notify'),
        _mediaTrack =
            lib.lookupFunction<_AplMediaTrackC, _AplMediaTrackD>('apl_media_set_track'),
        _mediaPlayback =
            lib.lookupFunction<_AplMediaPlaybackC, _AplMediaPlaybackD>('apl_media_set_playback'),
        _mediaWindow =
            lib.lookupFunction<_AplMediaWindowC, _AplMediaWindowD>('apl_media_set_window'),
        _setCallback = lib
            .lookupFunction<_SetEventCallbackC, _SetEventCallbackD>('apl_set_event_callback') {
    // 事件回调：listener 可从任意 OS 线程触发，事件按到达序进入 Dart 端口
    _eventCallable = NativeCallable<AplEventCallbackC>.listener(_onNativeEvent);
    _setCallback(_eventCallable.nativeFunction, nullptr);
  }

  static PlatformBindings? _instance;

  late final NativeCallable<AplEventCallbackC> _eventCallable;

  final _AplVersionD _version;
  final _AplInitD _init;
  final _AplCapsD _caps;
  final _AplPowerInhibitD _powerInhibit;
  final _AplPowerScreenD _powerScreen;
  final _AplWindowEventsD _windowEvents;
  final _AplInstanceAcquireD _instanceAcquire;
  final _AplNotifyD _notify;
  final _AplMediaTrackD _mediaTrack;
  final _AplMediaPlaybackD _mediaPlayback;
  final _AplMediaWindowD _mediaWindow;
  final _SetEventCallbackD _setCallback;

  // 四类事件广播流（ffi_* 实现订阅转译）
  final _commandCtrl = StreamController<MediaCommandEvent>.broadcast();
  final _seekCtrl = StreamController<AplSeekEvent>.broadcast();
  final _screenCtrl = StreamController<AplScreenEvent>.broadcast();
  final _windowCtrl = StreamController<AplWindowEvent>.broadcast();
  final _backendCtrl = StreamController<AplBackendEvent>.broadcast();

  /// 单实例仲裁：1=首实例；0=已有实例；<0=错误。
  int acquireInstance() => _instanceAcquire();

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

  /// 栈上指针仅在回调期间有效——同步取值后立即投递。
  static void _onNativeEvent(Pointer<AplEventFfi> event, Pointer<Void> userData) {
    final b = _instance;
    if (b == null || event == nullptr) return;
    final ref = event.ref;
    switch (ref.type) {
      case aplEventMediaCommand:
        b._commandCtrl.add(MediaCommandEvent(_commandFromNative(ref.u.command)));
      case aplEventMediaSeek:
        b._seekCtrl.add(AplSeekEvent(relMs: ref.u.seek.relMs, absMs: ref.u.seek.absMs));
      case aplEventScreenState:
        b._screenCtrl.add(AplScreenEvent(ref.u.active != 0));
      case aplEventWindowState:
        b._windowCtrl.add(AplWindowEvent(
          minimized: ref.u.window.minimized != 0,
          focused: ref.u.window.focused != 0,
        ));
      case aplEventBackendState:
        b._backendCtrl.add(AplBackendEvent(ref.u.backendLost != 0));
    }
  }

  static MediaCommand _commandFromNative(int raw) => switch (raw) {
        0 => MediaCommand.play,
        1 => MediaCommand.pause,
        2 => MediaCommand.toggle,
        3 => MediaCommand.stop,
        4 => MediaCommand.next,
        _ => MediaCommand.previous,
      };

  // ── 正向调用 ──

  int capabilities() => _caps();

  int setSleepInhibit(bool on) => _powerInhibit(on ? 1 : 0);

  int setScreenEvents(bool on) => _powerScreen(on ? 1 : 0);

  int setWindowEvents(bool on) => _windowEvents(on ? 1 : 0);

  int setPlayback(int state, int positionMs, double speed, double volume, int loop, int shuffle) =>
      _mediaPlayback(state, positionMs, speed, volume, loop, shuffle);

  int setWindow(int window) => _mediaWindow(window);

  /// 拷贝曲目元数据到原生内存发起调用；调用同步返回后立即释放。
  int setTrack(String? title, String? artist, String? album, int? durationMs, String? artUrl) {
    if (title == null) return _mediaTrack(nullptr);
    final meta = calloc<AplTrackMetaFfi>();
    final pointers = <Pointer<Uint8>>[];
    try {
      _fillString(meta.ref.title, title, pointers);
      _fillString(meta.ref.artist, artist, pointers);
      _fillString(meta.ref.album, album, pointers);
      meta.ref.durationMs = durationMs ?? -1;
      _fillString(meta.ref.artUrl, artUrl, pointers);
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

  /// 释放事件回调（isolate 退出前调用）；幂等。
  void dispose() {
    _setCallback(nullptr, nullptr);
    _eventCallable.close();
    _commandCtrl.close();
    _seekCtrl.close();
    _screenCtrl.close();
    _windowCtrl.close();
    _backendCtrl.close();
  }
}
