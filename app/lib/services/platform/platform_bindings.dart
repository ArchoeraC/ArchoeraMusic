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
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show File;
import 'dart:ui' show Color;

import 'package:ffi/ffi.dart';

import '../native_lib_paths.dart';
import 'live_install.dart';
import 'net.dart';
import 'system_media.dart';
import 'system_os.dart';
import 'system_status.dart';

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

/// archoera_shell_v1 输出 / 模式标记位（对齐 APL_OS_OUTPUT_*）。
const int aplOsOutputCurrent = 1 << 0;
const int aplOsOutputPreferred = 1 << 1;
const int aplOsOutputEnabled = 1 << 2;
const int aplOsOutputPrimary = 1 << 3;
const int aplCapWindowState = 1 << 5;
const int aplCapAppInstance = 1 << 6;
const int aplCapSystemAccent = 1 << 7;
const int aplCapSystemTheme = 1 << 8;
const int aplCapOsSession = 1 << 9;
const int aplCapSysStats = 1 << 10;
const int aplCapBluetooth = 1 << 11;
const int aplCapWifi = 1 << 12;

/// main 的协议唤醒原为 bit 9，与 [aplCapOsSession] 撞位 → 顺延到 13。
const int aplCapDeepLink = 1 << 13;

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

/// 蓝牙配对提示 / 结果（见 [netBtPairStart]；补齐无法用同步 Pair 处理的配对码场景）。
const int aplEventBtPairPrompt = 16;
const int aplEventBtPairResult = 17;

/// 配对提示类型（对齐 APL_BT_PAIR_*）。
const int aplBtPairConfirm = 1;
const int aplBtPairEnterPin = 2;
const int aplBtPairEnterPasskey = 3;
const int aplBtPairDisplay = 4;
const int aplBtPairAuthorize = 5;

/// main 的协议唤醒原为 8，与 OS/蓝牙配对事件撞位 → 顺延到 18。
const int aplEventDeepLink = 18;

const int aplAbiVersion = 2;

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

  /// 蓝牙配对提示（aplEventBtPairPrompt）。
  external AplBtPairPromptPayload btPairPrompt;

  /// 蓝牙配对结果（aplEventBtPairResult）。
  external AplBtPairResultPayload btPairResult;
}

/// 蓝牙配对提示载荷（对齐 C 侧 u.bt_pair_prompt）。
final class AplBtPairPromptPayload extends Struct {
  @Int32()
  external int kind;

  /// 设备/BlueZ 给出的 6 位码（0 = 无）。
  @Int32()
  external int passkey;

  /// 仅 DISPLAY 有意义：用户在设备上已输入的位数（BlueZ 每输入一位重发一次）。
  @Int32()
  external int entered;

  /// text 是否有效（1 = 需要在界面输入/展示）。
  @Int32()
  external int hasText;

  @Array(64)
  external Array<Uint8> text;
}

/// 蓝牙配对结果载荷（对齐 C 侧 u.bt_pair_result）。
final class AplBtPairResultPayload extends Struct {
  @Int32()
  external int ok;

  /// ok=0 时的负错误码。
  @Int32()
  external int err;
}

/// archoera_shell_v1 输出快照（对齐 AplOsOutput；字段顺序必须严格一致）。
final class AplOsOutputFfi extends Struct {
  @Uint32()
  external int id;

  @Array(64)
  external Array<Uint8> name;

  @Uint32()
  external int flags;

  @Uint32()
  external int width;

  @Uint32()
  external int height;

  @Uint32()
  external int scaleMilli;

  @Uint32()
  external int transform;

  @Uint32()
  external int refreshMillihz;

  @Uint32()
  external int modeCount;
}

/// archoera_shell_v1 输出模式（对齐 AplOsOutputMode）。
final class AplOsOutputModeFfi extends Struct {
  @Uint32()
  external int index;

  @Uint32()
  external int width;

  @Uint32()
  external int height;

  @Uint32()
  external int refreshMillihz;

  @Uint32()
  external int flags;
}

/// 系统资源快照（对齐 AplSysStats）。
final class AplSysStatsFfi extends Struct {
  @Int32()
  external int cpuCount;

  @Int32()
  external int cpuPercent;

  @Int64()
  external int memTotalKb;

  @Int64()
  external int memAvailableKb;

  @Int64()
  external int swapTotalKb;

  @Int64()
  external int swapFreeKb;

  @Int64()
  external int diskTotalKb;

  @Int64()
  external int diskFreeKb;

  @Int64()
  external int uptimeSec;

  @Int32()
  external int tempMillic;
}

/// 蓝牙状态（对齐 AplBtState）。
final class AplBtStateFfi extends Struct {
  @Int32()
  external int present;

  @Int32()
  external int powered;

  @Int32()
  external int discoverable;

  @Int32()
  external int pairable;

  @Int32()
  external int devicesConnected;

  external AplStringFfi adapterName;

  /// 自定义 URI scheme 唤醒：待取信号（u.deep_link=1）。
  @Int32()
  external int deepLink;
}

final class AplEventFfi extends Struct {
  @Int32()
  external int type;

  @Int32()
  external int pad;

  external AplEventPayload u;
}

// ── 函数签名 ───────────────────────────────────────────────────────

/// Live 安装向导：候选目标磁盘（与 C 侧 AplLiveDisk 一致）。
final class AplLiveDiskFfi extends Struct {
  external AplStringFfi name;
  @Int64()
  external int sizeBytes;
  external AplStringFfi model;
  external AplStringFfi transport;
  @Int32()
  external int isLive;
}

/// Live 安装向导：安装计划（与 C 侧 AplLivePlan 一致；字段顺序必须严格一致）。
final class AplLivePlanFfi extends Struct {
  external AplStringFfi disk;
  external AplStringFfi hostname;
  external AplStringFfi username;
  external AplStringFfi locale;
  external AplStringFfi timezone;
  external AplStringFfi keymap;
  external AplStringFfi fs;
  external AplStringFfi swap;
  @Int32()
  external int encrypt;
  @Int32()
  external int autologin;
  external AplStringFfi luksPassphrase;
  external AplStringFfi userPassword;
  external AplStringFfi rootPassword;
}

/// Live 安装向导：进度（与 C 侧 AplLiveInstallStatus 一致）。
final class AplLiveInstallStatusFfi extends Struct {
  @Int32()
  external int running;
  @Int32()
  external int done;
  @Int32()
  external int failed;
  @Int32()
  external int percent;
  external AplStringFfi message;
}

/// WiFi：概况（与 C 侧 AplWifiState 一致）。
final class AplWifiStateFfi extends Struct {
  @Int32()
  external int present;
  @Int32()
  external int enabled;
  @Int32()
  external int connected;
  @Int32()
  external int signal;
  external AplStringFfi ssid;
  external AplStringFfi ip;
  external AplStringFfi security;
}

/// WiFi：扫描到的一个 AP（与 C 侧 AplWifiNetwork 一致）。
final class AplWifiNetworkFfi extends Struct {
  external AplStringFfi ssid;
  @Int32()
  external int signal;
  @Int32()
  external int security;
  @Int32()
  external int connected;
  @Int32()
  external int saved;

  /// 频段（MHz）：24xx = 2.4G，5xxx = 5G；0 = 未知。
  @Int32()
  external int frequencyMhz;
}

/// 蓝牙：一个设备（与 C 侧 AplBtDevice 一致）。
final class AplBtDeviceFfi extends Struct {
  external AplStringFfi address;
  external AplStringFfi name;
  @Int32()
  external int paired;
  @Int32()
  external int connected;
  @Int32()
  external int rssi;
}

typedef _AplVersionC = Int32 Function();
typedef _AplInitC = Int32 Function();
typedef _AplShutdownC = Int32 Function();
typedef _AplCapsC = Uint32 Function();
typedef _AplPowerInhibitC = Int32 Function(Int32 on);
typedef _AplPowerScreenC = Int32 Function(Int32 on);
typedef _AplWindowEventsC = Int32 Function(Int32 on);
typedef _AplInstanceAcquireC = Int32 Function();
typedef _AplNotifyC = Int32 Function(Pointer<Utf8> title, Pointer<Utf8> body);
typedef _AplSysStatsC = Int32 Function(Pointer<AplSysStatsFfi> out);
typedef _AplBtStateC = Int32 Function(Pointer<AplBtStateFfi> out);
typedef _AplSystemAccentC =
    Int32 Function(Pointer<Int32> r, Pointer<Int32> g, Pointer<Int32> b);
typedef _AplSystemAccentSetEventsC = Int32 Function(Int32 on);
typedef _AplSystemThemeSetEventsC = Int32 Function(Int32 on);
typedef _AplOsSetEventsC = Int32 Function(Int32 on);
typedef _AplOsSetPercentC = Int32 Function(Int32 percent);
typedef _AplOsSetScreenC = Int32 Function(Int32 on);
typedef _AplOsSetModeC = Int32 Function(Int32 width, Int32 height);
typedef _AplOsKeyC = Int32 Function(Int32 keycode, Int32 state);
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
// deep link（main）：协议注册/注销、取回待处理 URI、次实例转发、置前窗口。
typedef _AplProtocolRegisterC = Int32 Function(Pointer<Utf8> scheme);
typedef _AplProtocolUnregisterC = Int32 Function(Pointer<Utf8> scheme);
typedef _AplDeepLinkTakeC = Int32 Function(Pointer<AplStringFfi> out);
typedef _AplDeepLinkForwardC = Int32 Function();
typedef _AplWindowActivateC = Int32 Function();

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
typedef _AplSysStatsD = int Function(Pointer<AplSysStatsFfi> out);
typedef _AplBtStateD = int Function(Pointer<AplBtStateFfi> out);
typedef _AplLiveAvailableC = Int32 Function();
typedef _AplLiveAvailableD = int Function();
typedef _AplLiveDiskListC =
    Int32 Function(
      Pointer<AplLiveDiskFfi> out,
      Uint32 max,
      Pointer<Uint32> count,
    );
typedef _AplLiveDiskListD =
    int Function(Pointer<AplLiveDiskFfi> out, int max, Pointer<Uint32> count);
typedef _AplLiveInstallStartC = Int32 Function(Pointer<AplLivePlanFfi> plan);
typedef _AplLiveInstallStartD = int Function(Pointer<AplLivePlanFfi> plan);
typedef _AplLiveInstallStatusC =
    Int32 Function(Pointer<AplLiveInstallStatusFfi> out);
typedef _AplLiveInstallStatusD =
    int Function(Pointer<AplLiveInstallStatusFfi> out);
typedef _AplWifiStateC = Int32 Function(Pointer<AplWifiStateFfi> out);
typedef _AplWifiStateD = int Function(Pointer<AplWifiStateFfi> out);
typedef _AplWifiScanC =
    Int32 Function(
      Pointer<AplWifiNetworkFfi> out,
      Uint32 max,
      Pointer<Uint32> count,
    );
typedef _AplWifiScanD =
    int Function(
      Pointer<AplWifiNetworkFfi> out,
      int max,
      Pointer<Uint32> count,
    );
typedef _AplWifiConnectC =
    Int32 Function(Pointer<Utf8> ssid, Pointer<Utf8> psk);
typedef _AplWifiConnectD = int Function(Pointer<Utf8> ssid, Pointer<Utf8> psk);
typedef _AplVoidIntC = Int32 Function();
typedef _AplVoidIntD = int Function();
typedef _AplStrIntC = Int32 Function(Pointer<Utf8> value);
typedef _AplStrIntD = int Function(Pointer<Utf8> value);
typedef _AplBtPairStartC = Int32 Function(Pointer<Utf8> address);
typedef _AplBtPairStartD = int Function(Pointer<Utf8> address);
typedef _AplBtPairReplyC = Int32 Function(Int32 accept, Pointer<Utf8> text);
typedef _AplBtPairReplyD = int Function(int accept, Pointer<Utf8> text);
typedef _AplIntArgC = Int32 Function(Int32 on);
typedef _AplIntArgD = int Function(int on);
typedef _AplBtDevicesC =
    Int32 Function(
      Pointer<AplBtDeviceFfi> out,
      Uint32 max,
      Pointer<Uint32> count,
    );
typedef _AplBtDevicesD =
    int Function(Pointer<AplBtDeviceFfi> out, int max, Pointer<Uint32> count);
typedef _AplSystemAccentD =
    int Function(Pointer<Int32> r, Pointer<Int32> g, Pointer<Int32> b);
typedef _AplSystemAccentSetEventsD = int Function(int on);
typedef _AplSystemThemeSetEventsD = int Function(int on);
typedef _AplOsSetEventsD = int Function(int on);
typedef _AplOsSetPercentD = int Function(int percent);
typedef _AplOsSetScreenD = int Function(int on);
typedef _AplOsSetModeD = int Function(int width, int height);
typedef _AplOsOutputListC =
    Int32 Function(
      Pointer<AplOsOutputFfi> out,
      Uint32 max,
      Pointer<Uint32> count,
    );
typedef _AplOsOutputListD =
    int Function(Pointer<AplOsOutputFfi> out, int max, Pointer<Uint32> count);
typedef _AplOsOutputModesC =
    Int32 Function(
      Uint32 outputId,
      Pointer<AplOsOutputModeFfi> out,
      Uint32 max,
      Pointer<Uint32> count,
    );
typedef _AplOsOutputModesD =
    int Function(
      int outputId,
      Pointer<AplOsOutputModeFfi> out,
      int max,
      Pointer<Uint32> count,
    );
typedef _AplOsOutputSetModeC = Int32 Function(Uint32 outputId, Uint32 index);
typedef _AplOsOutputSetModeD = int Function(int outputId, int index);
typedef _AplOsOutputSetUintC = Int32 Function(Uint32 outputId, Uint32 value);
typedef _AplOsOutputSetUintD = int Function(int outputId, int value);
typedef _AplOsKeyD = int Function(int keycode, int state);
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
// deep link（main）：协议注册/注销、取回待处理 URI、次实例转发、置前窗口。
typedef _AplProtocolRegisterD = int Function(Pointer<Utf8> scheme);
typedef _AplProtocolUnregisterD = int Function(Pointer<Utf8> scheme);
typedef _AplDeepLinkTakeD = int Function(Pointer<AplStringFfi> out);
typedef _AplDeepLinkForwardD = int Function();
typedef _AplWindowActivateD = int Function();

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

/// 蓝牙配对提示事件：界面据此弹出「确认配对码 / 输入 PIN」提示。
final class AplBtPairPromptEvent extends AplNativeEvent {
  const AplBtPairPromptEvent({
    required this.kind,
    required this.passkey,
    required this.entered,
    required this.hasText,
    required this.text,
  });

  /// 见 aplBtPair*：1=确认 2=输入PIN 3=输入配对码 4=在设备输入 5=授权。
  final int kind;

  /// 6 位配对码（0 = 无）。
  final int passkey;

  /// 仅 DISPLAY：用户在设备上已输入的位数。
  final int entered;
  final bool hasText;

  /// 需要在界面输入/展示的 PIN 或配对码（hasText 为真时有效）。
  final String text;
}

/// 蓝牙配对结果事件（一次异步配对结束）。
final class AplBtPairResultEvent extends AplNativeEvent {
  const AplBtPairResultEvent({required this.ok, required this.err});

  final bool ok;

  /// ok=false 时的负错误码。
  final int err;
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

/// deep link 到达信号（Dart 再调 [PlatformBindings.deepLinkTake] 取 URI）。
final class AplDeepLinkEvent extends AplNativeEvent {
  const AplDeepLinkEvent();
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
      // per-output（协议 v5）：缺失时显示设置退回旧的主输出接口。
      _osOutputList = _try(
        () => lib.lookupFunction<_AplOsOutputListC, _AplOsOutputListD>(
          'apl_os_output_list',
        ),
      ),
      _osOutputModes = _try(
        () => lib.lookupFunction<_AplOsOutputModesC, _AplOsOutputModesD>(
          'apl_os_output_modes',
        ),
      ),
      _osOutputSetMode = _try(
        () => lib.lookupFunction<_AplOsOutputSetModeC, _AplOsOutputSetModeD>(
          'apl_os_output_set_mode',
        ),
      ),
      _osOutputSetScale = _try(
        () => lib.lookupFunction<_AplOsOutputSetUintC, _AplOsOutputSetUintD>(
          'apl_os_output_set_scale',
        ),
      ),
      _osOutputSetTransform = _try(
        () => lib.lookupFunction<_AplOsOutputSetUintC, _AplOsOutputSetUintD>(
          'apl_os_output_set_transform',
        ),
      ),
      _osKey = _try(
        () => lib.lookupFunction<_AplOsKeyC, _AplOsKeyD>('apl_os_key'),
      ),
      _sysStats = _try(
        () => lib.lookupFunction<_AplSysStatsC, _AplSysStatsD>('apl_sys_stats'),
      ),
      _btState = _try(
        () => lib.lookupFunction<_AplBtStateC, _AplBtStateD>('apl_bt_state'),
      ),
      // Live 安装向导（仅 Live 镜像的桥接提供；缺失时整体降级）
      _liveAvailable = _try(
        () => lib.lookupFunction<_AplLiveAvailableC, _AplLiveAvailableD>(
          'apl_live_available',
        ),
      ),
      _liveDiskList = _try(
        () => lib.lookupFunction<_AplLiveDiskListC, _AplLiveDiskListD>(
          'apl_live_disk_list',
        ),
      ),
      _liveInstallStart = _try(
        () => lib.lookupFunction<_AplLiveInstallStartC, _AplLiveInstallStartD>(
          'apl_live_install_start',
        ),
      ),
      _liveInstallStatus = _try(
        () =>
            lib.lookupFunction<_AplLiveInstallStatusC, _AplLiveInstallStatusD>(
              'apl_live_install_status',
            ),
      ),
      // WiFi / 蓝牙（apl_wifi_* / apl_bt_*）
      _wifiState = _try(
        () => lib.lookupFunction<_AplWifiStateC, _AplWifiStateD>(
          'apl_wifi_state',
        ),
      ),
      _wifiScan = _try(
        () => lib.lookupFunction<_AplWifiScanC, _AplWifiScanD>('apl_wifi_scan'),
      ),
      _wifiConnect = _try(
        () => lib.lookupFunction<_AplWifiConnectC, _AplWifiConnectD>(
          'apl_wifi_connect',
        ),
      ),
      _wifiDisconnect = _try(
        () => lib.lookupFunction<_AplVoidIntC, _AplVoidIntD>(
          'apl_wifi_disconnect',
        ),
      ),
      _wifiSetEnabled = _try(
        () => lib.lookupFunction<_AplIntArgC, _AplIntArgD>(
          'apl_wifi_set_enabled',
        ),
      ),
      _wifiForget = _try(
        () => lib.lookupFunction<_AplStrIntC, _AplStrIntD>('apl_wifi_forget'),
      ),
      _btScanStart = _try(
        () =>
            lib.lookupFunction<_AplVoidIntC, _AplVoidIntD>('apl_bt_scan_start'),
      ),
      _btScanStop = _try(
        () =>
            lib.lookupFunction<_AplVoidIntC, _AplVoidIntD>('apl_bt_scan_stop'),
      ),
      _btDevices = _try(
        () => lib.lookupFunction<_AplBtDevicesC, _AplBtDevicesD>(
          'apl_bt_devices',
        ),
      ),
      _btPairStart = _try(
        () => lib.lookupFunction<_AplBtPairStartC, _AplBtPairStartD>(
          'apl_bt_pair_start',
        ),
      ),
      _btPairReply = _try(
        () => lib.lookupFunction<_AplBtPairReplyC, _AplBtPairReplyD>(
          'apl_bt_pair_reply',
        ),
      ),
      _btPair = _try(
        () => lib.lookupFunction<_AplStrIntC, _AplStrIntD>('apl_bt_pair'),
      ),
      _btConnect = _try(
        () => lib.lookupFunction<_AplStrIntC, _AplStrIntD>('apl_bt_connect'),
      ),
      _btDisconnect = _try(
        () => lib.lookupFunction<_AplStrIntC, _AplStrIntD>('apl_bt_disconnect'),
      ),
      _btForget = _try(
        () => lib.lookupFunction<_AplStrIntC, _AplStrIntD>('apl_bt_forget'),
      ),
      _btSetEnabled = _try(
        () =>
            lib.lookupFunction<_AplIntArgC, _AplIntArgD>('apl_bt_set_enabled'),
      ),
      // deep link（main）：协议注册/注销、取回待处理 URI、次实例转发、置前窗口。
      _protocolRegister =
          lib.lookupFunction<_AplProtocolRegisterC, _AplProtocolRegisterD>(
            'apl_protocol_register',
          ),
      _protocolUnregister =
          lib.lookupFunction<_AplProtocolUnregisterC, _AplProtocolUnregisterD>(
            'apl_protocol_unregister',
          ),
      _deepLinkTakeFn = lib.lookupFunction<_AplDeepLinkTakeC, _AplDeepLinkTakeD>(
        'apl_deep_link_take',
      ),
      _deepLinkForwardFn =
          lib.lookupFunction<_AplDeepLinkForwardC, _AplDeepLinkForwardD>(
            'apl_deep_link_forward',
          ),
      _windowActivateFn =
          lib.lookupFunction<_AplWindowActivateC, _AplWindowActivateD>(
            'apl_window_activate',
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
  final _AplProtocolRegisterD _protocolRegister;
  final _AplProtocolUnregisterD _protocolUnregister;
  final _AplDeepLinkTakeD _deepLinkTakeFn;
  final _AplDeepLinkForwardD _deepLinkForwardFn;
  final _AplWindowActivateD _windowActivateFn;
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
  final _AplOsOutputListD? _osOutputList;
  final _AplOsOutputModesD? _osOutputModes;
  final _AplOsOutputSetModeD? _osOutputSetMode;
  final _AplOsOutputSetUintD? _osOutputSetScale;
  final _AplOsOutputSetUintD? _osOutputSetTransform;
  final _AplOsKeyD? _osKey;
  final _AplSysStatsD? _sysStats;
  final _AplBtStateD? _btState;
  final _AplLiveAvailableD? _liveAvailable;
  final _AplLiveDiskListD? _liveDiskList;
  final _AplLiveInstallStartD? _liveInstallStart;
  final _AplLiveInstallStatusD? _liveInstallStatus;
  final _AplWifiStateD? _wifiState;
  final _AplWifiScanD? _wifiScan;
  final _AplWifiConnectD? _wifiConnect;
  final _AplVoidIntD? _wifiDisconnect;
  final _AplIntArgD? _wifiSetEnabled;
  final _AplStrIntD? _wifiForget;
  final _AplVoidIntD? _btScanStart;
  final _AplVoidIntD? _btScanStop;
  final _AplBtDevicesD? _btDevices;
  final _AplStrIntD? _btPair;
  final _AplBtPairStartD? _btPairStart;
  final _AplBtPairReplyD? _btPairReply;
  final _AplStrIntD? _btConnect;
  final _AplStrIntD? _btDisconnect;
  final _AplStrIntD? _btForget;
  final _AplIntArgD? _btSetEnabled;

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
  final _btPairPromptCtrl = StreamController<AplBtPairPromptEvent>.broadcast();
  final _btPairResultCtrl = StreamController<AplBtPairResultEvent>.broadcast();

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

  /// per-output 显示设置符号是否可用（协议 v5 桥接）。
  bool get osDisplayOutputsAvailable => _osOutputList != null;

  /// 读取全部输出快照（含完整模式列表）；不可用或失败返回空列表。
  List<OsDisplayOutput> osDisplayOutputs() {
    final fn = _osOutputList;
    if (fn == null) return const <OsDisplayOutput>[];
    const maxOutputs = 16;
    final out = calloc<AplOsOutputFfi>(maxOutputs);
    final count = calloc<Uint32>();
    try {
      if (fn(out, maxOutputs, count) < 0) return const <OsDisplayOutput>[];
      final n = count.value.clamp(0, maxOutputs);
      return <OsDisplayOutput>[
        for (var i = 0; i < n; i++)
          OsDisplayOutput(
            id: out[i].id,
            name: _cstr(out[i].name),
            enabled: out[i].flags & aplOsOutputEnabled != 0,
            primary: out[i].flags & aplOsOutputPrimary != 0,
            width: out[i].width,
            height: out[i].height,
            scaleMilli: out[i].scaleMilli,
            transform: out[i].transform,
            refreshMillihz: out[i].refreshMillihz,
            modes: _readOutputModes(out[i].id, out[i].modeCount),
          ),
      ];
    } finally {
      calloc.free(out);
      calloc.free(count);
    }
  }

  /// 某个输出的模式列表；失败返回空列表。
  List<OsDisplayMode> _readOutputModes(int outputId, int hint) {
    final fn = _osOutputModes;
    if (fn == null) return const <OsDisplayMode>[];
    final cap = hint > 64 ? hint : 64;
    final out = calloc<AplOsOutputModeFfi>(cap);
    final count = calloc<Uint32>();
    try {
      if (fn(outputId, out, cap, count) < 0) {
        return const <OsDisplayMode>[];
      }
      final n = count.value.clamp(0, cap);
      return <OsDisplayMode>[
        for (var i = 0; i < n; i++)
          OsDisplayMode(
            index: out[i].index,
            width: out[i].width,
            height: out[i].height,
            refreshMillihz: out[i].refreshMillihz,
            isCurrent: out[i].flags & aplOsOutputCurrent != 0,
            isPreferred: out[i].flags & aplOsOutputPreferred != 0,
          ),
      ];
    } finally {
      calloc.free(out);
      calloc.free(count);
    }
  }

  int osSetDisplayOutputMode(int outputId, int index) =>
      _osOutputSetMode?.call(outputId, index) ?? aplErrUnsupported;
  int osSetDisplayOutputScale(int outputId, int scaleMilli) =>
      _osOutputSetScale?.call(outputId, scaleMilli) ?? aplErrUnsupported;
  int osSetDisplayOutputTransform(int outputId, int transform) =>
      _osOutputSetTransform?.call(outputId, transform) ?? aplErrUnsupported;
  int osKey(int keycode, int state) =>
      _osKey?.call(keycode, state) ?? aplErrUnsupported;

  /// 屏幕键盘按键注入符号是否可用（旧版桥接可能缺失）。
  bool get osKeySymbolsAvailable => _osKey != null;

  /// deep link 到达（Dart 再调 [deepLinkTake] 取 URI）。
  final _deepLinkCtrl = StreamController<AplDeepLinkEvent>.broadcast();

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

  // ── Live 安装向导（apl_live_*）────────────────────────────────────

  /// 读取 C ABI 里的定长 NUL 结尾字符串（AplOsOutput.name）。
  String _cstr(Array<Uint8> arr) {
    final bytes = arr.elements;
    var end = 0;
    while (end < bytes.length && bytes[end] != 0) {
      end++;
    }
    return utf8.decode(bytes.sublist(0, end), allowMalformed: true);
  }

  String _liveStr(AplStringFfi v) {
    final data = v.data;
    if (v.len == 0 || data.address == 0) return '';
    return utf8.decode(data.asTypedList(v.len), allowMalformed: true);
  }

  void _livePut(AplStringFfi slot, String value, List<Pointer<Uint8>> keep) {
    if (value.isEmpty) {
      slot.data = nullptr;
      slot.len = 0;
      return;
    }
    final bytes = utf8.encode(value);
    final p = malloc<Uint8>(bytes.length + 1);
    p.asTypedList(bytes.length).setAll(0, bytes);
    p[bytes.length] = 0;
    keep.add(p);
    slot.data = p;
    slot.len = bytes.length;
  }

  /// 是否 Live 环境（桥接缺失/非 Live 返回 false）。
  bool liveAvailable() {
    final fn = _liveAvailable;
    if (fn == null) return false;
    return fn() == 1;
  }

  /// 候选目标磁盘；不可用或失败返回空列表。
  List<LiveDisk> liveDisks() {
    final fn = _liveDiskList;
    if (fn == null) return const <LiveDisk>[];
    const max = 32;
    final out = calloc<AplLiveDiskFfi>(max);
    final count = calloc<Uint32>();
    try {
      if (fn(out, max, count) != 0) return const <LiveDisk>[];
      final n = count.value;
      return <LiveDisk>[
        for (var i = 0; i < n; i++)
          LiveDisk(
            name: _liveStr(out[i].name),
            sizeBytes: out[i].sizeBytes,
            model: _liveStr(out[i].model),
            transport: _liveStr(out[i].transport),
            isLive: out[i].isLive != 0,
          ),
      ];
    } finally {
      calloc.free(out);
      calloc.free(count);
    }
  }

  // ── WiFi / 蓝牙（apl_wifi_* / apl_bt_*）──────────────────────────

  WifiState? netWifiState() {
    final fn = _wifiState;
    if (fn == null) return null;
    final out = calloc<AplWifiStateFfi>();
    try {
      if (fn(out) != 0) return null;
      return WifiState(
        present: out.ref.present != 0,
        enabled: out.ref.enabled != 0,
        connected: out.ref.connected != 0,
        signal: out.ref.signal,
        ssid: _liveStr(out.ref.ssid),
        ip: _liveStr(out.ref.ip),
        security: _wifiSecFromInt(_liveStr(out.ref.security)),
      );
    } finally {
      calloc.free(out);
    }
  }

  WifiSecurity _wifiSecFromInt(String raw) {
    switch (raw) {
      case 'open':
        return WifiSecurity.open;
      case 'psk':
        return WifiSecurity.psk;
      default:
        return WifiSecurity.unknown;
    }
  }

  List<WifiNetwork> netWifiScan() {
    final fn = _wifiScan;
    if (fn == null) return const <WifiNetwork>[];
    const max = 64;
    final out = calloc<AplWifiNetworkFfi>(max);
    final count = calloc<Uint32>();
    try {
      if (fn(out, max, count) != 0) return const <WifiNetwork>[];
      final n = count.value;
      return <WifiNetwork>[
        for (var i = 0; i < n; i++)
          WifiNetwork(
            ssid: _liveStr(out[i].ssid),
            signal: out[i].signal,
            security:
                WifiSecurity.values[out[i].security.clamp(
                  0,
                  WifiSecurity.values.length - 1,
                )],
            connected: out[i].connected != 0,
            saved: out[i].saved != 0,
            frequencyMhz: out[i].frequencyMhz,
          ),
      ];
    } finally {
      calloc.free(out);
      calloc.free(count);
    }
  }

  bool netWifiConnect(String ssid, {String? password}) {
    final fn = _wifiConnect;
    if (fn == null) return false;
    final s = ssid.toNativeUtf8();
    final p = (password ?? '').toNativeUtf8();
    try {
      return fn(s, p) == 0;
    } finally {
      malloc.free(s);
      malloc.free(p);
    }
  }

  bool netWifiDisconnect() {
    final fn = _wifiDisconnect;
    return fn == null ? false : fn() == 0;
  }

  bool netWifiSetEnabled(bool on) {
    final fn = _wifiSetEnabled;
    return fn == null ? false : fn(on ? 1 : 0) == 0;
  }

  bool netWifiForget(String ssid) {
    final fn = _wifiForget;
    if (fn == null) return false;
    final s = ssid.toNativeUtf8();
    try {
      return fn(s) == 0;
    } finally {
      malloc.free(s);
    }
  }

  List<BtDevice> netBtDevices() {
    final fn = _btDevices;
    if (fn == null) return const <BtDevice>[];
    const max = 64;
    final out = calloc<AplBtDeviceFfi>(max);
    final count = calloc<Uint32>();
    try {
      if (fn(out, max, count) != 0) return const <BtDevice>[];
      final n = count.value;
      return <BtDevice>[
        for (var i = 0; i < n; i++)
          BtDevice(
            address: _liveStr(out[i].address),
            name: _liveStr(out[i].name),
            paired: out[i].paired != 0,
            connected: out[i].connected != 0,
            rssi: out[i].rssi,
          ),
      ];
    } finally {
      calloc.free(out);
      calloc.free(count);
    }
  }

  bool netBtScanStart() {
    final fn = _btScanStart;
    return fn == null ? false : fn() == 0;
  }

  bool netBtScanStop() {
    final fn = _btScanStop;
    return fn == null ? false : fn() == 0;
  }

  bool _btCall(_AplStrIntD? fn, String address) {
    if (fn == null) return false;
    final a = address.toNativeUtf8();
    try {
      return fn(a) == 0;
    } finally {
      malloc.free(a);
    }
  }

  bool netBtPair(String address) => _btCall(_btPair, address);

  /// 异步配对：立即返回（0=已发起），过程中的提示/结果经事件流下发。
  /// 需要配对码/PIN 的设备必须走这条（同步 [netBtPair] 会失败）。
  int netBtPairStart(String address) {
    final fn = _btPairStart;
    if (fn == null) return aplErrUnsupported;
    final p = address.toNativeUtf8();
    try {
      return fn(p);
    } finally {
      malloc.free(p);
    }
  }

  /// 回答最近的配对提示：[accept]=false 拒绝；[text] 为 PIN/配对码（无则 null）。
  int netBtPairReply(bool accept, String? text) {
    final fn = _btPairReply;
    if (fn == null) return aplErrUnsupported;
    final p = (text == null || text.isEmpty) ? nullptr : text.toNativeUtf8();
    try {
      return fn(accept ? 1 : 0, p);
    } finally {
      if (p != nullptr) malloc.free(p);
    }
  }

  bool netBtConnect(String address) => _btCall(_btConnect, address);
  bool netBtDisconnect(String address) => _btCall(_btDisconnect, address);
  bool netBtForget(String address) => _btCall(_btForget, address);

  bool netBtSetEnabled(bool on) {
    final fn = _btSetEnabled;
    return fn == null ? false : fn(on ? 1 : 0) == 0;
  }

  /// 写计划并启动安装单元。
  bool liveInstallStart(LivePlan plan) {
    final fn = _liveInstallStart;
    if (fn == null) return false;
    final out = calloc<AplLivePlanFfi>();
    final keep = <Pointer<Uint8>>[];
    try {
      _livePut(out.ref.disk, plan.disk, keep);
      _livePut(out.ref.hostname, plan.hostname, keep);
      _livePut(out.ref.username, plan.username, keep);
      _livePut(out.ref.locale, plan.locale, keep);
      _livePut(out.ref.timezone, plan.timezone, keep);
      _livePut(out.ref.keymap, plan.keymap, keep);
      _livePut(out.ref.fs, plan.fs, keep);
      _livePut(out.ref.swap, plan.swap, keep);
      out.ref.encrypt = plan.encrypt ? 1 : 0;
      out.ref.autologin = plan.autologin ? 1 : 0;
      _livePut(out.ref.luksPassphrase, plan.luksPassphrase, keep);
      _livePut(out.ref.userPassword, plan.userPassword, keep);
      _livePut(out.ref.rootPassword, plan.rootPassword, keep);
      return fn(out) == 0;
    } finally {
      for (final p in keep) {
        malloc.free(p);
      }
      calloc.free(out);
    }
  }

  /// 读取安装进度；不可用返回 null。
  LiveInstallStatus? liveInstallStatus() {
    final fn = _liveInstallStatus;
    if (fn == null) return null;
    final out = calloc<AplLiveInstallStatusFfi>();
    try {
      if (fn(out) != 0) return null;
      return LiveInstallStatus(
        running: out.ref.running != 0,
        done: out.ref.done != 0,
        failed: out.ref.failed != 0,
        percent: out.ref.percent,
        message: _liveStr(out.ref.message),
      );
    } finally {
      calloc.free(out);
    }
  }

  /// 系统资源 / 蓝牙符号是否可用（旧版桥接缺失时返回 false）。
  bool get sysStatsSymbolsAvailable => _sysStats != null;
  bool get bluetoothSymbolsAvailable => _btState != null;

  /// Live 安装向导符号是否可用（仅 Live 镜像的桥接带这些符号）。
  bool get liveSymbolsAvailable => _liveAvailable != null;

  /// WiFi / 蓝牙符号是否可用。
  bool get wifiSymbolsAvailable => _wifiState != null;
  bool get bluetoothControlSymbolsAvailable => _btDevices != null;

  /// 系统资源快照；不可用/失败返回 null。
  SysStats? sysStats() {
    final fn = _sysStats;
    if (fn == null) return null;
    final out = calloc<AplSysStatsFfi>();
    try {
      if (fn(out) != aplOk) return null;
      final s = out.ref;
      return SysStats(
        cpuCount: s.cpuCount,
        cpuPercent: s.cpuPercent,
        memTotalKb: s.memTotalKb,
        memAvailableKb: s.memAvailableKb,
        swapTotalKb: s.swapTotalKb,
        swapFreeKb: s.swapFreeKb,
        diskTotalKb: s.diskTotalKb,
        diskFreeKb: s.diskFreeKb,
        uptimeSec: s.uptimeSec,
        tempMillic: s.tempMillic,
      );
    } finally {
      calloc.free(out);
    }
  }

  /// 蓝牙状态；不可用/失败返回 null。
  BluetoothState? bluetoothState() {
    final fn = _btState;
    if (fn == null) return null;
    final out = calloc<AplBtStateFfi>();
    try {
      if (fn(out) != aplOk) return null;
      final s = out.ref;
      final name = s.adapterName.data;
      return BluetoothState(
        present: s.present != 0,
        powered: s.powered != 0,
        discoverable: s.discoverable != 0,
        pairable: s.pairable != 0,
        devicesConnected: s.devicesConnected,
        adapterName: name == nullptr
            ? null
            : name.cast<Utf8>().toDartString(length: s.adapterName.len),
      );
    } finally {
      calloc.free(out);
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
  Stream<AplBtPairPromptEvent> get btPairPromptEvents =>
      _btPairPromptCtrl.stream;
  Stream<AplBtPairResultEvent> get btPairResultEvents =>
      _btPairResultCtrl.stream;

  /// deep link 到达（Dart 再调 [deepLinkTake] 取 URI）。
  Stream<AplDeepLinkEvent> get deepLinkEvents => _deepLinkCtrl.stream;

  /// 注册/注销当前用户的 URI scheme 处理程序（免提权）；[aplOk]=成功。
  int protocolRegister(String scheme) {
    final s = scheme.toNativeUtf8();
    try {
      return _protocolRegister(s);
    } finally {
      malloc.free(s);
    }
  }

  int protocolUnregister(String scheme) {
    final s = scheme.toNativeUtf8();
    try {
      return _protocolUnregister(s);
    } finally {
      malloc.free(s);
    }
  }

  /// 取出一个待处理 deep link URI（无则 null；内部静态缓冲，已即时拷贝）。
  String? deepLinkTake() {
    final out = calloc<AplStringFfi>();
    try {
      if (_deepLinkTakeFn(out) <= 0) return null;
      final ref = out.ref;
      if (ref.data == nullptr || ref.len <= 0) return null;
      return ref.data.cast<Utf8>().toDartString(length: ref.len);
    } finally {
      calloc.free(out);
    }
  }

  /// 次实例转发自身 argv 中的 URI：1=已转发 / 0=无 / <0=错误。
  int deepLinkForward() => _deepLinkForwardFn();

  /// 置前/激活主窗口（<0=失败）。
  int activateWindow() => _windowActivateFn();

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
      case aplEventBtPairPrompt:
        b._btPairPromptCtrl.add(
          AplBtPairPromptEvent(
            kind: ref.u.btPairPrompt.kind,
            passkey: ref.u.btPairPrompt.passkey,
            entered: ref.u.btPairPrompt.entered,
            hasText: ref.u.btPairPrompt.hasText != 0,
            text: b._cstr(ref.u.btPairPrompt.text),
          ),
        );
      case aplEventBtPairResult:
        b._btPairResultCtrl.add(
          AplBtPairResultEvent(
            ok: ref.u.btPairResult.ok != 0,
            err: ref.u.btPairResult.err,
          ),
        );
      case aplEventDeepLink:
        b._deepLinkCtrl.add(const AplDeepLinkEvent());
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
    _deepLinkCtrl.close();
    _instance = null;
  }
}
