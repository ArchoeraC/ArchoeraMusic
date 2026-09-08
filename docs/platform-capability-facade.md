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

1. 接口**按能力分、数量克制**：SystemPower / SystemMedia / SystemLocation 级别；不按平台调用拆、不按
   单一实现的方法列表膨胀；
2. **平台缺失 = 空实现静默降级**（能力探测 + 回退），不是抛错中断；
3. **跨层边界不破**：App 侧外观 ↔ 引擎侧（输出/总线）职责清晰，接口文档各管一段；
4. 新增能力先在此文档登记接口与平台矩阵，再落实现。

## 6. 现状迁移

- `power_saver.dart` 的 Linux D-Bus 逻辑搬迁为 `SystemPower.linux`（接口不变，行为不回归）；
- `weather_api.dart` 的 `system` 定位分支收敛为 `SystemLocation.system` 适配（回退链保留在天气层）；
- `SystemMedia` 为新增能力（现无），落地时同时接蓝牙耳机传输控制与键盘媒体键。
