# 平台能力外观层（Platform Capability Facade）设计

> 状态：设计稿 · 2026-09-08
> 主题：播放器与 **OS 系统能力** 的统一接口层（防休眠 / 媒体会话与蓝牙耳机控制 / 系统定位等）。
> 与 `docs/engine-master-worker-scheduling.md`（主控/线程执行调度）主题分开；本层为 **App 侧外观**，
> 引擎侧音频输出问题不在此层（见 §2 边界）。
> 沿用原则：仓库 `docs/CROSS_PLATFORM_CAPABILITY_IMPROVEMENT.md` 的「只有最底层原生原语按平台各写
> adapter，上面共享一份」论证。

---

## 1. 背景与目标

播放器依赖若干 **OS 系统能力**，每平台底层原语完全不同，且目前散落在各 Dart 服务 / 引擎层：

- **防休眠/屏保抑制**：Linux 用 D-Bus 会话总线（`org.freedesktop.ScreenSaver`/portal），Windows /
  macOS / Android 各是不同 API；
- **蓝牙耳机传输控制（暂停/切歌/播放）**：耳机 AVRCP 按键 → OS 统一收进「媒体会话」（Linux MPRIS /
  Win SMTC / macOS Now Playing / Android MediaSession）→ 派发给注册方；语法差异由 OS 消化；
- **天气系统定位**：Linux GeoClue2 / Windows 定位 / 移动定位，已有「系统 → IP」回退链。

**目标**：按**能力**定义少量契约接口，每平台一个实现藏在接口后，主程序只依赖接口。
由此**只维护「几个接口 + 每平台几个实现文件」**，而不是把 `Platform.isXxx` 分支散落到业务代码。

## 2. 范围与边界

### 2.1 首期三个能力接口

| 能力接口 | 方法（草案） | 各平台原语 | 现状依托 |
|---|---|---|---|
| **SystemPower** | `setSleepInhibit(bool)` / `Stream<bool> screenState` | Linux D-Bus（ScreenSaver/portal）· Win `SetThreadExecutionState` · macOS `NSProcessInfo` · Android wakelock/Doze | `power_saver.dart`（现仅 Linux，D-Bus） |
| **SystemMedia**（含蓝牙耳机控制） | `setNowPlaying(Track)` / `clearNowPlaying()` / `setPlaybackState(state,pos,speed)` / `Stream<MediaCommand> commands`（play/pause/next/prev/seek/stop） | Linux MPRIS（D-Bus）· Win SMTC · macOS `MPRemoteCommandCenter`+NowPlaying · Android MediaSession+AudioFocus | 暂无（新增） |
| **SystemLocation** | `Future<Geo?> locate()`（失败抛可回退错误） | Linux GeoClue2 · Win Windows Location · 移动系统定位 | `weather_api.dart` 的 `system` 分支（:195-216） |

> **SystemMedia 的蓝牙语义**：播放器不直连耳机。耳机 AVRCP → OS 媒体会话 → 统一命令派发到
> `commands`；「蓝牙耳机兼容」= 正确注册 OS 媒体会话并消费一套统一命令语义，各平台回调语法藏在实现里。
>
> **SystemWindow（2026-09-10 新增）**：`Stream<WindowState> state`（minimized/focused 快照），
> 窗口最小化/失焦/隐藏探测收进原生桥接（`platform-native-bridge.md` §3.4）——Linux X11 /
> Windows WndProc 子类化 / macOS NSWindow 通知；纯 Wayland 等不支持场景由 Dart 回退
> window_manager 监听（既有路径）。

### 2.2 不属于本层（边界标注）

| 项 | 归属 | 说明 |
|---|---|---|
| **蓝牙 HFP/输出兼容**（声道/采样率/HFP sink，`player.c`） | 引擎音频层（`audio-kernel-zig.md` §15 + `kernel_bridge.h`） | 是"声音能否出来"的输出问题，不是 App 侧媒体会话外观；引擎内处理并可按需经总线上报 |
| **天气数据拉取**（Open-Meteo / geocode / ipwho） | 网络服务层（现有 `weather_api.dart`） | 本层只负责"系统坐标获取"，城市名/天气数据不进本层 |
| **OS 键盘媒体键** | 与 SystemMedia 同源（SMTC/MPRIS 天然覆盖键盘媒体键） | 属本层 SystemMedia；自定义全局快捷键（`app_shortcuts`）是 App 内行为，默认不扩进 OS 能力外观 |
| **系统占用/日志面板** | `engine-master-worker-scheduling.md` §2.4 模块总线 | 遥测/日志走总线；能力注册状态可作总线上报主题之一 |

## 3. 契约示例（Dart 草案）与平台实现矩阵

```dart
// app/lib/services/platform/ —— 每个能力一个文件 + 每平台实现
abstract interface class SystemMedia {
  Future<void> setNowPlaying(TrackInfo t);
  Future<void> clearNowPlaying();
  Future<void> setPlaybackState(PlayState s, int positionMs, double speed);
  Stream<MediaCommand> get commands; // play/pause/next/prev/seek/stop
}

abstract interface class SystemPower {
  Future<bool> setSleepInhibit(bool on, {String reason});
  Stream<bool> get screenState;
}
```

| 平台 | SystemPower | SystemMedia | SystemLocation |
|---|---|---|---|
| Linux | D-Bus（现有 power_saver 抽出） | MPRIS over D-Bus | GeoClue2 |
| Windows | `SetThreadExecutionState` | SMTC | Windows Location |
| macOS | `NSProcessInfo` activity | `MPRemoteCommandCenter` + NowPlaying | CoreLocation（按需） |
| Android | wakelock / Doze | MediaSession + AudioFocus | 系统定位 |
| Fallback | 空实现（静默降级） | 空实现（不注册=耳机键无效） | 抛"可回退"错误 → 上层 IP 定位 |

**降级规则（沿用现有语义）**：能力检测失败/无实现 → **静默降级或显式回退**，绝不中断业务——
对齐 `power_saver.dart` 的 try-catch 降级与 `weather_api.dart` 的「系统 → IP」回退链。

## 4. 实现形态

- **位置**：`app/lib/services/platform/<capability>/`：`<capability>.dart`（接口契约）+
  `<platform>.dart`（实现）+ 工厂（条件导入 / 平台注册表），主程序仅注入接口；
- **纯 Dart 可行的能力**（D-Bus、GeoClue）用 Dart 包 + 条件导入；必须进 OS 原生 API 的
  （SMTC / NowPlaying / CoreLocation）建议走自有原生模块或插件通道，避免每平台各养一个 Flutter 插件；
- **引擎侧相关**（蓝牙 HFP 等）走 `kernel_bridge` C ABI 与 `engine-master-worker-scheduling.md` §2.4 总线，
  Dart 外观不 `Platform.isXxx` 判断引擎内部后端，引擎也不依赖 Dart 的 Platform。

## 5. 治理规则

1. 接口**按能力分、数量克制**：SystemPower / SystemMedia / SystemLocation / SystemWindow 级别；不按平台调用拆、不按
   单一实现的方法列表膨胀；
2. **降级分两档（2026-09-10 用户决策）**：能力缺失（平台无此能力/未编译后端）→ **空实现
   静默降级**；执行失败（系统服务拒绝、断连）→ **显式告警**——接口层抛出失败状态，UI 侧
   经统一 toast/snackbar 明示（如「禁用系统休眠失败」「媒体会话已断开」），绝不静默吞掉
   也不中断业务。后台优化类订阅（熄屏/窗口事件）失败仅 debug 日志回落，不打扰用户；
3. **跨层边界不破**：App 侧外观 ↔ 引擎侧（输出/总线）职责清晰，接口文档各管一段；
4. 新增能力先在此文档登记接口与平台矩阵，再落实现。

## 6. 现状迁移

- `power_saver.dart` 的 Linux D-Bus 逻辑搬迁为 `SystemPower.linux`（接口不变，行为不回归）；
- `weather_api.dart` 的 `system` 定位分支收敛为 `SystemLocation.system` 适配（回退链保留在天气层）；
- `SystemMedia` 为新增能力（现无），落地时同时接蓝牙耳机传输控制与键盘媒体键。

---

## 7. 落地记录（2026-09-10）

### 7.1 范围澄清（用户决策）

- **后台播放不在本层**：后台播放 = 托盘隐藏（`tray_integration`，`windowManager.hide()`）
  + 引擎独立线程持续转码/播放 + 节能降帧协商（`power_saver.dart` 窗口事件分支），
  全部由 Dart 侧既有链路完成，能力已就绪——不作为外观层接口登记；
- 本层首期落地 **SystemPower + SystemMedia** 两个能力（SystemLocation 后置）；
- **「键盘输入」语义 = OS 媒体键**（键盘播放/暂停键、蓝牙耳机 AVRCP 按键），经 OS 媒体
  会话统一进入 `SystemMedia.commands`；应用内快捷键（`app_shortcuts.dart` 的 Space/方向键/
  Ctrl+F 等）是 App 内行为，**不进**本层（§2.2 已定）。

### 7.2 SystemPower 收窄

`power_saver.dart` 现混 4 职责，仅**熄屏检测**归 `SystemPower`；其余归属：

| power_saver 职责 | 归属 | 说明 |
|---|---|---|
| 窗口事件降帧（minimize/blur/hide → 帧率上限） | → `SystemWindow`（桥接事件）+ 留守 window_manager 回退 | 2026-09-10 决策：探测收进原生桥接（X11/WndProc/NSWindow）；桥接未置能力位（纯 Wayland）回退 window_manager |
| 引擎事件降频协商（50/500/1000ms） | 留在 power_saver | engine-event-push-plan §4.1 |
| **熄屏检测**（Linux D-Bus `ActiveChanged`） | ✅ → `SystemPower.screenState`（P1 已落地） | Linux 经自研 D-Bus；Win/macOS 待 P3/P4（bridge §7.1） |
| 唤醒锁（`wakelock_plus`） | ✅ Linux → `SystemPower.setSleepInhibit`（原生）；Win/macOS 暂 `WakelockSystemPower` 兜底 | Linux P1 已切原生；P3/P4 后移除 wakelock_plus（bridge §7.1） |

`setSleepInhibit` 语义沿用现状：**调用方仍负责「仅在播放中抑制」的门禁**（power_saver
的 `setPlaying` 双条件不变），外观层只暴露开关，不内嵌播放状态机。

### 7.3 SystemMedia 落地形态（已被 §8 原生桥接取代）

- ~~Linux：纯 Dart `dbus` 包实现 MPRIS~~ → **改为原生 Zig 模块 + 自研 D-Bus**，
  见 `docs/platform-native-bridge.md`（2026-09-10 用户决策：接口统一化走 dart:ffi
  动态链接，全 extern struct 零 JSON、零子进程；Linux D-Bus 自研，避免
  「一半 FFI 一半 Dart 包」的裂缝）；
- **Windows SMTC / macOS Now Playing**：同在该原生模块内实现（WinRT COM vtable /
  ObjC runtime 直调）；
- `system_power.dart` / `system_media.dart` 的 **Dart 契约保持不变**（主程序仍只依赖
  接口），实现由「纯 Dart」替换为「FFI 绑定 + 空实现回退」；
- 范围：**仅桌面三平台**（Windows / Linux / macOS），Android/iOS 不在本期（用户决策）。

### 7.4 实现位置（修订）

```
app/native/platform/                  # Zig 原生模块（libarchoera_platform，apl_* C ABI）
app/lib/services/platform/            # Dart 契约（system_power/system_media）+ FFI 绑定
```

详见 `docs/platform-native-bridge.md`。

### 7.5 实施进度

- **P1 Linux Power ✅（2026-09-10）**：休眠抑制（ScreenSaver Inhibit）+ 熄屏订阅
  经原生桥接；失败 toast；Windows/macOS 暂 `WakelockSystemPower` 兜底。
- **P2 Linux MPRIS ✅（2026-09-10）**：`MediaSessionHost` 挂载于 `app.dart`，
  元数据/播放态 → MPRIS，媒体键/耳机按键 → `playbackNotifier`；断连 toast
  （`toastMediaSessionLost`）。Win SMTC / macOS Now Playing 待 P3b/P4。
- **P3a Windows Power/窗口 ✅（2026-09-10，交叉编译验证）**：休眠抑制 +
  熄屏 + 窗口状态经原生桥接；`power_saver` 按 caps 用 `SystemWindow`
  （桥接可用优先，否则 window_manager 兜底）。SMTC 待 P3b。
- **P3b Windows SMTC ✅（2026-09-10，WSL interop 真机验证）**：winmd 解析
  vtable 槽位 + WinRT COM 直调；读回 PlaybackStatus/IsEnabled 校验通过。
- **P4 macOS ✅（2026-09-10，交叉编译验证）**：抑制/熄屏/窗口/媒体会话经
  `dlopen`+`objc_msgSend` 运行时直调；aarch64/x86_64-macos 编译通过，待真机验收。
- **P5 Linux 窗口状态 ✅（2026-09-10，编译验证）**：会话检测 + GTK/GDK 统一
  模式（X11/Wayland 皆覆盖，消除回退）；`wakelock_plus` 兜底已移除。
