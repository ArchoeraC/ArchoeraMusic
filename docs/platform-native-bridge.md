# 平台能力原生桥接（Platform Native Bridge）设计

> 状态：设计稿 · 2026-09-10
> 定位：`docs/platform-capability-facade.md` §7.3/§7.4 修订的落地形态——**平台能力统一化**由
> 独立 Zig 原生模块承载：Dart 只调用统一接口（`SystemPower` / `SystemMedia`），**全部平台
> 转发、系统请求与事件回传都在 Zig 内完成**，Dart 侧不出现任何平台原语。
>
> 硬性约束（用户决策 2026-09-10）：
> 1. **零 JSON**：ABI 全部 extern struct + 定长字段 / UTF-8 指针+长度（对齐
>    `engine-master-worker-scheduling.md` §2.3 `ZkMetaInfo`「规避 JSON」决策）；
> 2. **零子进程**：同进程动态链接库，`dart:ffi` 直调（类比 `engine_bindings.dart` 加载
>    `libarchoera_mediaengine`）；
> 3. **范围 = 桌面三平台**：Windows / Linux / macOS；Android/iOS 不在本期（后续如需另议，
>    JVM 侧 MediaSession 无法纯 dylib 承载）。

---

## 1. 架构总览

```
Dart（app/lib/services/platform/）
  system_power.dart / system_media.dart     ← 契约（已建，保持不变，主程序仅依赖这层）
  platform_capabilities.dart                ← 工厂：FFI 实现 ⇄ Noop 空实现（按能力位图）
  platform_bindings.dart                    ← dart:ffi 绑定（apl_* 符号 + NativeCallable.listener）
        │  DynamicLibrary.open('libarchoera_platform')   同进程，无子进程、无 JSON
        ▼
Zig 原生模块（app/native/platform/ → libarchoera_platform.*）
  core.zig        生命周期 / 能力位图 / 事件汇聚线程 → Dart 回调
  backend_linux.zig     自研 D-Bus（传输+编组）→ ScreenSaver + MPRIS
  backend_windows.zig   SetThreadExecutionState + WinRT SMTC（COM vtable 直调）
  backend_macos.zig     NSProcessInfo + MPRemoteCommandCenter / MPNowPlayingInfoCenter
        │  （ObjC runtime / dispatch_async 经 dlopen libSystem）
        ▼
OS：D-Bus 会话总线 / WinRT 媒体会话 / macOS Now Playing
```

- **正向**（Dart → OS）：`apl_power_*` / `apl_media_*` 同步调用，返回错误码；
- **反向**（OS → Dart）：媒体键 / 蓝牙 AVRCP / 熄屏事件，由 Zig 在 OS 回调线程接住，
  经 `AplEvent`（POD 结构体）→ 注册的 `AplEventCallback` → Dart `NativeCallable.listener`
  直接派发（Dart 3.1+ 支持任意原生线程回调 Dart，事件按到达序串行进入 Dart 端口队列，
  无需 Zig 侧再排队、无需轮询）。

## 2. 目录结构与产物

```
app/native/platform/
├── build.zig                    # Zig 0.16；单产物：libarchoera_platform.so/.dll/.dylib
├── include/archoera_platform.h  # C ABI 契约（唯一头文件，Dart 绑定与 Zig 实现共同依据）
├── src/
│   ├── core.zig                 # apl_* 导出、能力位图、事件线程与回调管理
│   ├── dbus/                    # 自研 D-Bus（仅 Linux 编入）
│   │   ├── transport.zig        # unix socket + SASL EXTERNAL + Hello + AddMatch/RequestName
│   │   ├── message.zig          # D-Bus 编组/解组（header + body，LE）
│   │   └── mpris.zig            # MPRIS2 服务实现（属性缓存 + Seeked 信号 + 方法分发）
│   └── backend/
│       ├── backend_linux.zig    # ScreenSaver.Inhibit + ActiveChanged + MPRIS 导出
│       ├── backend_windows.zig  # SetThreadExecutionState + SMTC（RoGetActivationFactory
│       │                        #   + SystemMediaTransportControlsInterop::GetForWindow）
│       └── backend_macos.zig    # NSProcessInfo beginActivity + MPNowPlayingInfoCenter +
│                               #   MPRemoteCommandCenter（objc_msgSend + dispatch main）
└── test/                        # zig build test（编组往返 / 能力位图 / 事件结构）

app/lib/services/platform/
├── system_power.dart / system_media.dart   # 契约（已建）
├── platform_capabilities.dart              # 工厂：加载成功且有对应能力 → FFI 实现；否则 Noop
└── platform_bindings.dart                  # FFI 绑定（加载路径对齐 native_lib_paths.dart）
```

| 平台 | 产物 | 打包 |
|---|---|---|
| Linux | `libarchoera_platform.so` | 随 `native/` 布局（同 mediaengine，见 `ffi-libs-layout-plan.md`，打包脚本增补拷贝项） |
| Windows | `archoera_platform.dll` | 同上 |
| macOS | `libarchoera_platform.dylib` | 同上 |

构建顺序与 audio-engine 一致：`zig build -Doptimize=ReleaseFast` 纯交叉编译三平台，
不引入 CMake / 三平台脚本。

## 3. C ABI（`include/archoera_platform.h` 草案）

### 3.1 基础约定

- 符号前缀 `apl_`；所有函数 `callconv(.C)`；错误码整型返回（跨 FFI 无异常）：

```c
#define APL_OK              0
#define APL_ERR_UNSUPPORTED -1   /* 本平台无此能力（未编译后端 / 缺系统服务） */
#define APL_ERR_BACKEND     -2   /* 后端调用失败（D-Bus 断连 / WinRT 拒绝等） */
#define APL_ERR_STATE       -3   /* 未 init / 参数非法 */

int32_t apl_abi_version(void);           /* 契约版本，Dart 侧校验 */
int32_t apl_init(void);                  /* 进程级一次；重复调用幂等 OK */
int32_t apl_shutdown(void);              /* join 线程、释放抑制、注销媒体会话 */
uint32_t apl_capabilities(void);         /* 能力位图 */
```

- **能力位图**（Dart 据此决定 FFI 实现是否接管，缺位图 → Noop 静默降级）：

```c
#define APL_CAP_POWER_INHIBIT      (1u << 0)   /* 三平台全覆盖 */
#define APL_CAP_POWER_SCREEN_STATE (1u << 1)   /* 三平台全覆盖（2026-09-10 决策） */
#define APL_CAP_MEDIA_SESSION      (1u << 2)
#define APL_CAP_MEDIA_SEEK         (1u << 3)   /* 系统 UI 可拖进度条 */
#define APL_CAP_MEDIA_ARTWORK      (1u << 4)
#define APL_CAP_WINDOW_STATE       (1u << 5)   /* 窗口最小化/失焦事件 */
```

### 3.2 字符串与元数据（零 JSON）

```c
typedef struct AplString { const char* data; size_t len; } AplString;
/* data 允许为 NULL（= 字段缺失）；UTF-8；调用期间有效，Zig 需要留存时自行拷贝 */

typedef struct AplTrackMeta {
    AplString title;        /* 必填 */
    AplString artist;       /* 多人由 Dart 以 " / " 预拼接 */
    AplString album;
    int64_t   duration_ms;  /* <0 = 未知 */
    AplString art_url;      /* http(s) URL 或本地绝对路径；NULL = 无封面 */
} AplTrackMeta;
```

**所有权**：Dart → Zig 的结构体与字符串仅在调用期间有效（Dart 侧保证存活到同步调用返回）；
Zig 内部需要跨调用留存（SMTC 异步 set、MPRIS 属性缓存）时**在调用内深拷贝**；
Zig → Dart 方向只有 POD 事件，**永不向 Dart 返回需释放的内存**。

### 3.3 SystemPower（三平台全覆盖，2026-09-10 决策）

```c
/* 防休眠抑制。
   Linux = org.freedesktop.ScreenSaver.Inhibit（会话总线直连）
   Windows = SetThreadExecutionState(ES_CONTINUOUS|ES_SYSTEM_REQUIRED)（专用常驻线程）
   macOS = NSProcessInfo beginActivity(NSActivityIdleSleepDisabled) */
int32_t apl_power_set_sleep_inhibit(int32_t on);

/* 订阅熄屏/屏保激活事件（见 3.6 APL_EVENT_SCREEN_STATE），三平台全覆盖：
   Linux = ScreenSaver ActiveChanged 信号
   Windows = PowerSettingRegisterNotification(GUID_CONSOLE_DISPLAY_STATE)
   macOS = NSWorkspace screensaverDidStart / screensDidSleep 通知 */
int32_t apl_power_set_screen_events(int32_t on);
```

> 能力位图上 `POWER_INHIBIT` / `POWER_SCREEN_STATE` 在三平台恒置位；个别桌面环境缺失
> 服务（如无 ScreenSaver 的极简 WM）不降位图，而是**执行时返回 `APL_ERR_BACKEND`**
> ——由 Dart 侧显式 toast 告警（§6 告警规则），与「平台根本没有该能力」的 Noop 静默
> 降级相区分。

### 3.4 SystemWindow（窗口状态，2026-09-10 新增）

```c
/* 订阅窗口最小化/失焦事件（见 3.6 APL_EVENT_WINDOW_STATE）。
   Windows = 子类化 Flutter 顶层 WndProc（WM_SIZE/WM_ACTIVATE）
   macOS = NSWindow DidMiniaturize/DidBecomeKey/DidResignKey 通知（主线程）
   Linux = GTK/GDK 统一模式（会话检测 + dlopen libgtk-3，覆盖 X11/Wayland） */
int32_t apl_window_set_events(int32_t on);
```

事件语义与 `window_manager` WindowListener 对齐（minimized/focused/hidden 由
Zig 折算为 `{minimized, focused}` 二元组），`power_saver` 的档位判定逻辑不变。

### 3.5 SystemMedia

```c
/* 注册/清除当前曲目；track=NULL 等价清除 */
int32_t apl_media_set_track(const AplTrackMeta* track);

/* 更新播放态；Zig 缓存并推送到媒体会话。
   state: 0=stopped 1=playing 2=paused
   loop:  0=list 1=one（映射 MPRIS LoopStatus Playlist/Track / SMTC 不暴露则忽略）
   位置行为：playing 时 Zig 用单调时钟自 position_ms 外推，供 MPRIS Position
   属性读取（Get 调用即时回复）；Dart 位置事件到达即校正基准 */
int32_t apl_media_set_playback(int32_t state, int64_t position_ms,
                               double speed, double volume,
                               int32_t loop, int32_t shuffle);

/* Windows 专用：SMTC 需与顶层窗口关联（GetForWindow）。
   Dart 经 runner 补的一行导出取 HWND（见 §6.2）；非 Windows 平台忽略 */
int32_t apl_media_set_window(int64_t hwnd);
```

### 3.6 反向事件（OS → Dart）

```c
typedef enum {
    APL_EVENT_MEDIA_COMMAND = 1,  /* u.command */
    APL_EVENT_MEDIA_SEEK    = 2,  /* u.seek：rel_ms != 0 取相对，否则取 abs_ms */
    APL_EVENT_SCREEN_STATE  = 3,  /* u.screen：active */
    APL_EVENT_WINDOW_STATE  = 4,  /* u.window：minimized / focused（即时布尔快照） */
    APL_EVENT_BACKEND_STATE = 5,  /* u.backend：lost（后端断连，Dart 显式告警 + Noop 回落） */
    APL_EVENT_SYSTEM_ACCENT = 6,  /* 主题色变更（无载荷；收到后重读 apl_system_accent 去重） */
} AplEventType;

typedef enum { APL_CMD_PLAY=0, APL_CMD_PAUSE, APL_CMD_TOGGLE, APL_CMD_STOP,
               APL_CMD_NEXT, APL_CMD_PREV } AplCommand;

typedef struct AplEvent {
    int32_t type;
    int32_t _pad;
    union {
        int32_t command;
        struct { int64_t rel_ms; int64_t abs_ms; } seek;
        int32_t active;                 /* SCREEN_STATE */
        struct { int32_t minimized; int32_t focused; } window;
        int32_t backend_lost;           /* BACKEND_STATE：1=断连 */
    } u;
} AplEvent;

typedef void (*AplEventCallback)(const AplEvent* event, void* user_data);
/* event 仅在回调期间有效（栈上）；user_data 由 Dart 提供原样回传 */

int32_t apl_set_event_callback(AplEventCallback cb, void* user_data);
/* cb=NULL 注销。回调可能在任意 OS 线程触发（WinRT free thread / D-Bus IO 线程 /
   macOS main thread），Dart 侧必须用 NativeCallable.listener */
```

Dart 侧映射（`platform_bindings.dart`）：`MediaCommandEvent` / `MediaSeekEvent` /
`screenState` 流，与 `system_media.dart` / `system_power.dart` 契约一一对应——
**契约层与主程序完全不感知 FFI 细节**。

### 3.7 SystemAccent（系统主题色）

```c
/* 读取 DE 主题色：0=成功并写 *r/*g/*b(0-255)；<0=不可得。
   Linux : kreadconfig6/5(kdeglobals [General] AccentColor) → gsettings 兜底
   Windows: HKCU\...\DWM\AccentColor(ABGR DWORD) → DwmGetColorizationColor
   macOS : NSColor.controlAccentColor(10.14+) → sRGB */
int32_t apl_system_accent(int32_t *r, int32_t *g, int32_t *b);

/* 订阅/取消变更事件：变更时回调 APL_EVENT_SYSTEM_ACCENT（无载荷）。
   Linux : XDG portal SettingChanged / KDE KGlobalSettings.notifyChange
   Windows: RegNotifyChangeKeyValue(DWM 键，后台线程)
   macOS : NSDistributedNotificationCenter + NSSystemColorsDidChangeNotification */
int32_t apl_system_accent_set_events(int32_t on);
```

能力位 `APL_CAP_SYSTEM_ACCENT`（1<<7）。事件只表示“可能已变”，Dart
（`systemAccentProvider`，StreamProvider）收到后重读并**按颜色去重**。

## 4. 各平台实现要点

### 4.1 Linux（自研 D-Bus，~1.5–2k 行）

- **为什么自研**：避免「一半 FFI（原生模块）+ 一半 Dart dbus 包」的裂缝；对齐内核 P2
  「最小外部依赖」哲学。协议面小：本模块只需会话总线的
  `org.freedesktop.ScreenSaver`（Inhibit/UnInhibit/ActiveChanged）+ 自身 MPRIS 导出，
  不做通用 D-Bus 库。
- **transport.zig**：`$DBUS_SESSION_BUS_ADDR` 解析（unix:path= 为主）→ connect →
  `\0 AUTH EXTERNAL <uid hex>\r\n`（getuid）→ `BEGIN` → `Hello`；此后 IO 线程
  poll（`Message` 收发），断连自动重连一次，失败置能力降级并回报。
- **message.zig**：头部（endian/type/flags/serial/length/fields）+ body 编组；
  用到的类型仅 `s / u / x / d / b / o / g / v / a{sv} / as`，覆盖 ScreenSaver 与
  MPRIS2/Player 全部属性与方法；`zig build test` 做编组↔解组往返向量。
- **MPRIS**：`org.mpris.MediaPlayer2.archoera`（被占则追加 `.instance<pid>`）+
  `/org/mpris/MediaPlayer2` 两接口；方法 `Quit`（→ APL_CMD_STOP 交 Dart 决策）与
  Player 方法（Play/Pause/PlayPause/Stop/Next/Previous/Seek/SetPosition）→ 事件回调；
  `Seeked` 信号在 Dart seek 校正时发出；`CanGoNext/CanSeek` 等按队列状态恒真/恒假
  （首期恒真，Dart 命令落空即忽略，行为等价）。
- **休眠抑制**：`org.freedesktop.ScreenSaver.Inhibit("ArchoeraMusic", reason)`，
  保存 cookie 供 UnInhibit；KDE/GNOME 均实现该接口（portal 依赖不再需要——
  wakelock_plus 的 Linux 路径即 portal，本实现改为直连会话总线，语义等价）。
- **窗口状态（P5，已落地）**：**会话检测 + GTK/GDK 统一模式**（`linux_window.zig`）
  ——dlopen libgtk-3/libgdk-3/libglib-2.0，取应用自身 GtkWindow，经
  `g_main_context_invoke` 汇入 GTK 主线程 + `g_timeout_add(500ms)` 轻轮询
  `gtk_window_is_active` / `gdk_window_get_state(ICONIFIED)` 折算 `{minimized, focused}`。
  GDK 已抽象 X11/Wayland → **两种会话均覆盖**，不再回退 window_manager；
  `detectSession()`（WAYLAND_DISPLAY/DISPLAY）用于能力门控与日志。

### 4.2 Windows

- **抑制**：专用常驻线程 `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)`
  （ES_CONTINUOUS 按线程生效，故线程常驻；off 时清除标志）。
- **SMTC**：IO 线程 `RoInitialize(MTA)` → `RoGetActivationFactory(SystemMediaTransportControls)`
  → `ISystemMediaTransportControlsInterop::GetForWindow(hwnd)`；元数据
  `SystemMediaTransportControlsDisplayUpdater`（title/artist/album/thumbnail）；
  进度 `UpdateTimelineProperties`；按钮事件 `ButtonPressed` → 事件回调。
  COM 调用全部手写 vtable（无 cppwinrt 依赖）。**封面/时间轴（已实现）**：
  `RandomAccessStreamReference.CreateFromUri`（http URL → `Windows.Foundation.Uri`
  → `put_Thumbnail`；**本地路径** → `StorageFile.GetFileFromPathAsync` 轮询等待
  → `CreateFromFile`）+ `ISystemMediaTransportControls2.UpdateTimelineProperties`
  （进度条）+ `put_PlaybackRate`（1.0/0.0 供系统外推进度）。IID 由本机 winmd 解析
  （已按 ECMA 1-based 行号修正关联并实测校验）。封面解析在**后台线程**执行
  （本地 `GetFileFromPathAsync` 可能耗时，避免阻塞 `setNowPlaying`）；关键路径
  经 `OutputDebugStringA` 输出（DebugView 可见：`apl/smtc: ...`），便于排查
  「面板不显示」。
- **HWND 获取**：`windows/runner/main.cpp` 增一行导出 `int64_t get_flutter_window()`
  （类比 audio-engine C 壳哲学，改动 <5 行）；Dart 启动时 FFI 取得并传入
  `apl_media_set_window`。兜底：未接通时 `GetForegroundWindow()` 于窗口创建后取一次。
- **熄屏检测**：`PowerSettingRegisterNotification(GUID_CONSOLE_DISPLAY_STATE,
  DEVICE_NOTIFY_THREAD)`（IO 线程注册，线程消息收 `POWERBROADCAST_SETTING`：
  0=关屏 1=开屏）→ `APL_EVENT_SCREEN_STATE`；注册失败（老系统/权限）时
  `apl_power_set_screen_events` 返回 `APL_ERR_BACKEND`（Dart toast 告警）。
- **窗口状态**：`SetWindowLongPtrW(GWLP_WNDPROC)` 子类化 Flutter 顶层窗口，拦截
  `WM_SIZE(SIZE_MINIMIZED)` / `WM_ACTIVATE` / `WM_SYSCOMMAND(SC_MINIMIZE)`，
  折算事件后**必调原 WndProc**（不吞消息，零回归）。

### 4.3 macOS

- **抑制**：`[NSProcessInfo beginActivityWithOptions:reason:]`
  （`NSActivityIdleSleepDisabled`）→ 保存 activity token，off 时 `endActivity`。
- **熄屏检测**：`NSWorkspace.sharedWorkspace` 的 `screensaverDidStartNotification` /
  `screensDidSleepNotification`（`NSWorkspaceDidWakeNotification` 复位）→
  `NSNotificationCenter` 观察者（主线程）→ `APL_EVENT_SCREEN_STATE`。
- **窗口状态**：Flutter 主 `NSWindow`（runner 导出句柄）的
  `NSWindowDidMiniaturizeNotification` / `NSWindowDidBecomeKeyNotification` /
  `NSWindowDidResignKeyNotification` 观察者 → `APL_EVENT_WINDOW_STATE`。
- **媒体会话**：`MPNowPlayingInfoCenter`（字典：title/artist/album/duration/
  elapsedTime/rate/**artwork**，封面经 `NSImage`+`MPMediaItemArtwork`）+
  `MPRemoteCommandCenter`（play/pause/toggle/next/prev/stop/**changePlaybackPosition**
  → addTarget:action: → 事件回调；seek 读 `positionTime`）。
  全部经 `dlopen` frameworks + `objc_msgSend` 函数指针直调，不引入 ObjC 源文件；
  所有 ObjC 调用经 `dispatch_async(main_queue)` 汇聚到主线程（媒体会话 API 要求）。

> Windows/macOS 的 `HWND` / `NSWindow*` 句柄统一经 runner 导出 `get_flutter_window()`
> 获取（Dart 传入 `apl_media_set_window`，窗口/媒体后端各自解释句柄类型）。

## 5. 线程模型

| 线程 | 归属 | 职责 |
|---|---|---|
| Dart 主 isolate | Dart | 仅同步 `apl_*` 调用 + 收事件 |
| apl IO 线程（1 条，`apl_init` 建） | Zig | Linux：D-Bus poll/编组；Windows：WinRT apartment + SMTC 事件；macOS：仅发起 `dispatch_async`（实际 ObjC 调用在系统主线程） |
| OS 回调线程 | OS | SMTC ButtonPressed / D-Bus 方法调用 / MPRemoteCommand handler——一律汇聚到 IO 线程或直接经 `NativeCallable.listener` 投递（事件为 POD，无竞争） |

- 回调注销线程安全：`apl_set_event_callback(NULL)` 置原子指针后即生效；
- `apl_shutdown`：置停机位 → 唤醒 IO 线程 → join → 释放抑制/注销媒体会话 → 幂等返回。

## 6. Dart 接线

1. `platform_capabilities.dart` 工厂：启动时 `DynamicLibrary.open`（路径解析复用
   `native_lib_paths.dart` 的 native/ 布局逻辑）→ `apl_abi_version` 校验 →
   `apl_capabilities` → 有能力位则构造 `FfiSystemPower` / `FfiSystemMedia` /
   `FfiSystemWindow`，否则 `Noop*`（能力缺失 = 静默降级，门禁规则不变）；
2. **失败显式告警（2026-09-10 用户决策）**：能力缺失走静默，**执行失败必须显式**——
   `apl_*` 返回非 `APL_OK` / `APL_ERR_BACKEND` 或 `APL_EVENT_BACKEND_STATE(lost)` 时，
   Dart 实现层把失败向上抛（接口方法返回 `false`/抛 `PlatformCapabilityException`），
   UI 侧经统一 toast/snackbar 明示（如「禁用系统休眠失败：桌面环境不支持」/
   「系统媒体会话已断开」）。告警点约定：
   - `apl_power_set_sleep_inhibit` 失败 → 「禁用休眠」设置项即时 toast；
   - `apl_power_set_screen_events` / `apl_window_set_events` 失败 → 仅 debug 日志
     + 静默回落（节能是后台优化，不打断用户；与抑制失败的用户感知级别不同）；
   - `APL_EVENT_BACKEND_STATE(lost)` → 媒体会话断连 toast（一次性，重连成功不 toast）；
3. **power_saver.dart 瘦身**：熄屏监听与 wakelock 调用替换为 `SystemPower` 注入；
   **窗口事件改接 `SystemWindow`**（桥接位图含 `WINDOW_STATE` 时），未置位场景
   （纯 Wayland）**回退 window_manager 监听**（既有路径保留至各平台对齐）；
   引擎事件降频协商留守（facade §7.2）；
4. **SystemMedia 绑定**（新）：`playbackProvider` 监听 → `setTrack`（title/artist/
   album/duration/cover）+ `setPlayback`（playing/position/speed/volume/loop/shuffle）；
   `commands` 流 → `playbackNotifier.toggle/playNext/playPrevious/stop/seek`；
   与托盘菜单命令同源语义（tray_integration 对齐）；
5. **依赖清理**（P1/P2 验收后）：`wakelock_plus`、`dbus` 从 pubspec 移除
   （三桌面全覆盖；`window_manager` 保留——托盘/窗口几何等仍在用，仅事件监听让位桥接）；
   geolocator 留给天气定位，SystemLocation 不在本期。

## 7. 分阶段实施与验收

| 阶段 | 内容 | 出口标准 |
|---|---|---|
| **P0 骨架** | build.zig + 头文件 + core（init/caps/回调/事件分发）+ Dart 绑定/工厂/Noop/异常类型 + 打包布局增补 | `zig build` 三平台产物；`flutter analyze` 绿；Dart 侧 Noop 降级路径生效 |
| **P1 Linux Power** | D-Bus transport/message + Inhibit + ActiveChanged + 失败 toast 接线 | 播放中 GNOME/KDE 不休眠；无 ScreenSaver 环境显式 toast；熄屏模拟触发 screenState；power_saver 行为零回归 |
| **P2 Linux MPRIS** | mpris.zig 服务导出 + 命令/seek 事件 + BACKEND_STATE | `playerctl status/metadata/next/pause/position 10+` 全通；断连 toast；耳机 AVRCP（经 desktop 会话）切歌可用 |
| **P3 Windows** | 抑制 + 熄屏（PowerSetting）+ SMTC + 窗口状态（WndProc）+ runner 导出 | 播放中不休眠；媒体面板元数据/控制/拖进度全通；最小化/失焦降帧与 window_manager 等效 |
| **P4 macOS** | beginActivity + NSWorkspace 熄屏 + Now Playing/RemoteCommand + NSWindow 状态 | 合盖不断播（插电）；控制中心媒体卡片可控制；熄屏/窗口事件与 Win 对齐 |
| **P5 Linux 窗口状态** | 会话检测 + GTK/GDK 统一模式（dlopen libgtk-3，X11/Wayland 皆覆盖） | 最小化/失焦事件与 window_manager 等效；无回退（消除 Wayland 缺口） |
| **收尾** | 移除 wakelock_plus/dbus 依赖；文档状态更新 | pubspec 清理；`flutter test` 全绿 |

每阶段：`zig build test`（编组/事件向量）+ `flutter analyze` + 手动验收记录回填本文档。

### 7.1 实施进度（回填）

| 阶段 | 状态 | 落地内容 / 验收 |
|---|---|---|
| **P0 骨架** | ✅ 2026-09-10 | `app/native/platform`（build.zig + `archoera_platform.h` + core 事件分发 + 三平台后端 stub）；Dart 绑定/工厂/Noop/失败类型/SystemWindow 契约；打包（linux/windows CMake + macOS pbxproj + build-linux.sh）；`zig build test` 5/5、三平台交叉编译、`flutter analyze` 全绿 |
| **P1 Linux Power** | ✅ 2026-09-10 | 自研 D-Bus（`dbus/message.zig` 编组↔解组往返 9 例 + `dbus/transport.zig` 地址解析/AUTH EXTERNAL/Hello/读取权认领）；`backend_linux.zig` ScreenSaver Inhibit/UnInhibit + ActiveChanged 订阅 + 泵线程 + BACKEND_STATE；`zig build test` **19/19**（含真实会话总线 Hello、两连接信号端到端）；Dart `SystemPower` 接线 + 失败 toast（l10n ×9）；工厂 FFI/兜底分流 |
| P2 Linux MPRIS | ✅ 2026-09-10 | `dbus/mpris.zig`：`org.mpris.MediaPlayer2[.archoera]` 名称申请 + Root/Player/Properties/Introspectable 方法分发 + 属性 Get/GetAll/Set + `PropertiesChanged` 推送 + 位置单调外推；`backend_linux` 能力位图扩 `MEDIA_SESSION\|MEDIA_SEEK\|MEDIA_ARTWORK`；Dart `MediaSessionHost` 接线（元数据/播放态同步、命令→`playbackNotifier`、断连 toast）。`zig build test` **22/22**（含真实总线 GetAll + Play 端到端）；`caps=31` |
| P3a Windows Power/窗口 | ✅ 2026-09-10（**WSL interop 真机验证**） | `backend_windows.zig`：SetThreadExecutionState（`CreateThread` 专用常驻线程抑制）+ PowerSettingRegisterNotification(GUID_CONSOLE_DISPLAY_STATE, DEVICE_NOTIFY_CALLBACK) 熄屏 + `FindWindowW` 发现 Flutter 顶层窗口 + WndProc 子类化窗口状态；`build.zig` 链 user32/powrprof。真机冒烟（`zig build win-smoke`，WSL 直跑 exe）：`caps=0x23`、抑制 on/off=OK、熄屏注册=OK、无 Flutter 窗口时 window_events 优雅返回 -2、shutdown 干净。Dart `power_saver` 按 caps 接入 `SystemWindow` |
| P3b Windows SMTC | ✅ 2026-09-10（**WSL interop 真机验证**；含封面缩略图 + 时间轴） | `win_smtc.zig`：WinRT COM vtable 直调。**权威来源**：本机 `Windows.Media.winmd`（ECMA-335）解析出方法声明顺序（vtable 槽位）+ `[Guid]`（IID `ISystemMediaTransportControls`=99FA3FF4-…），interop IID 取自 mingw 头。`RoInitialize/RoGetActivationFactory/WindowsCreateString` 经 `LoadLibrary("combase.dll")` 运行时解析（无 x86_64 导入库）；事件委托手写 COM（`add_ButtonPressed` → `get_Button` → apl 命令）。真机冒烟：`set_track/set_playback=0`、**读回 PlaybackStatus=Playing(3)/IsEnabled=1 校验槽位**、窗口事件触发。未做：时间轴（ISystemMediaTransportControls2）、缩略图 |
| P4 macOS | ✅ 2026-09-10（**交叉编译验证**，待真机；含封面 + changePlaybackPosition） | `backend_macos.zig`：无 SDK 头 → 全程 `dlopen`+`objc_msgSend` 运行时直调（不 `@cImport` 框架头、不链框架，仅 libSystem dlopen/dlsym）；观察者/远程命令目标用运行时 ObjC 类（`objc_allocateClassPair`+`class_addMethod`）。覆盖 NSProcessInfo beginActivity 抑制、NSWorkspace 熄屏通知、NSWindow 窗口状态通知、MPNowPlayingInfoCenter + MPRemoteCommandCenter（play/pause/toggle/next/prev/stop）。aarch64/x86_64-macos 交叉编译通过 |
| P5 Linux 窗口状态 | ✅ 2026-09-10（编译验证，待真机） | **会话检测 + GTK/GDK 统一模式**：`linux_window.zig` 经 `dlopen` libgtk-3/libgdk-3/libglib-2.0 取应用自身 GtkWindow，`g_main_context_invoke` 汇入 GTK 主线程 + `g_timeout_add(500ms)` 轻轮询 `gtk_window_is_active`/`gdk_window_get_state(ICONIFIED)`；**同时覆盖 X11 与 Wayland**（GDK 已抽象），消除 Wayland 回退 window_manager。`detectSession()`（WAYLAND_DISPLAY/DISPLAY）用于能力门控与日志 |

**过渡兜底（P3/P4 前不回归）**：桥接未置 Power 能力位时，工厂注入
`WakelockSystemPower`（wakelock_plus 插件）——Windows/macOS 休眠抑制维持现状；
P3/P4 原生落地后该实现与 `wakelock_plus` 依赖一并移除（§7 收尾）。

**验收环境说明**：本机开发会话无 `org.freedesktop.ScreenSaver` / `org.gnome.ScreenSaver`
服务（headless/受限会话），`Inhibit` 正确返回 `APL_ERR_BACKEND` → Dart 侧 toast；
真实 GNOME/KDE 会话下 `Inhibit` 返回 OK。反向事件链路已由「两连接信号端到端」测试覆盖
（无需真实 ScreenSaver 服务）。

### 7.2 SMTC 实现（P3b，已解阻）

原阻塞（缺 WinRT ABI 头/SDK）已通过**解析本机 `Windows.Media.winmd`** 解决：
ECMA-335 元数据的接口方法声明顺序即 WinRT vtable 槽位顺序；IID 由 winmd 内
`[Guid]` 校验（`ISystemMediaTransportControls` = `99FA3FF4-1742-42A6-902E-087D41F965EC`），
`ISystemMediaTransportControlsInterop` IID 取自 mingw 头。`combase.dll` 无 x86_64
导入库 → `LoadLibrary`+`GetProcAddress` 运行时解析。真机（WSL interop）验证
vtable 槽位正确（写读回一致）。

### 7.3 依赖与图标清理（2026-09-10）

- Dart 移除已无引用的 `dbus` 依赖（Linux D-Bus 已由原生桥接接管）；
  三平台原生抑制齐备后移除 `wakelock_plus` 与 `WakelockSystemPower` 兜底
  （桥接缺失时 `NoopSystemPower` 静默降级）。
- 图标库：删除 116 个未被 registry 引用的孤儿 source SVG + 3 个死常量
  （`borderRadius`/`dotCircleOutline`/`miniplayer`），`source = registry = dart = 引用 = 211`。
  字体暂含 3 个孤儿字形（无 node_modules 未重生成，无害；下次全量重生成自然收敛）。

### 7.4 Windows 平台修复（2026-09-11，待真机验证）

针对「Windows 下可多开实例」「蓝牙耳机 / 媒体面板按键全无响应（但面板能显示曲目）」
「系统主题色恒读不到」：

- **单实例（native）**：`backend_windows.zig` 用命名互斥体
  `CreateMutexW("Local\\ArchoeraMusic.SingleInstance")` + `ERROR_ALREADY_EXISTS`
  实现（此前恒返回 1 放行）。`Local\` 会话命名空间 = 每登录会话一个实例，语义对齐
  Linux `XDG_RUNTIME_DIR` 文件锁 / macOS 文件锁；句柄持有至进程退出，`apl_shutdown` 关闭。
- **单实例（移除 Dart 兜底）**：`platform_capabilities.dart` 的
  `acquireSingleInstance()` 不再在桥接缺失时返回 `true`（旧兜底会掩盖桥接损坏并
  放任多开）；改为抛 `StateError`，`main.dart` 捕获后写 stderr 并 `exit(1)`——
  缺桥接时显式失败，绝不静默多开。
- **SMTC 按钮**：`win_smtc.zig` 事件委托 `QueryInterface` 修正——旧实现对所有 IID
  一律回 `S_OK`，会让 WinRT 误以为委托实现了 `IInspectable` / `IMarshal` 并按错位
  vtable 槽调用（`Invoke` 被当成 `GetIids` / `GetUnmarshalClass`），导致
  `add_ButtonPressed` 看似成功但 `ButtonPressed` 永不回调。现明确对
  `IInspectable` / `IMarshal` 返回 `E_NOINTERFACE`，其余（含 WinRT 运行期生成的
  委托 IID）应答并正确 `AddRef`。另注：Flutter 默认 UI 线程与平台线程合并，
  平台线程 `CoInitializeEx(APARTMENTTHREADED)` 为 STA → 委托须应答
  `IAgileObject`（QI 未拒绝即应答）。
- **媒体键兜底**：`backend_windows.zig` 子类化 WndProc 处理 `WM_APPCOMMAND`
  （`APPCOMMAND_MEDIA_*` → 统一命令），覆盖 SMTC 非当前会话时系统退化的旧通路。
- **系统主题色**：`backend_windows.zig` 预定义句柄 `HKEY_CURRENT_USER` 修正为 64 位
  符号扩展值 `0xFFFFFFFF80000001`（`(HKEY)(ULONG_PTR)((LONG)0x80000001)`；旧写
  `0x80000001` 在 64 位下非法）——此前 `RegGetValueW` / `RegOpenKeyExW` 全失败，
  `apl_system_accent` 恒返回 null，主题色与「颜色变更事件」双双失效。
- **诊断**：`apl/smtc:` 前缀经 `OutputDebugStringA` 输出 `RoInitialize` /
  `add_ButtonPressed` 的 HRESULT、QI 被拒 IID、`ButtonPressed` 到达；`win-smoke`
  增印 `instance_acquire` / `button_registered`。真机验收用 DebugView 观察。
- 附：修复 `win-smoke` 编译（补齐 `win_common.zig` 的 `WNDCLASSW` /
  `RegisterClassW` / `CreateWindowExW` / `DefWindowProcW` / `DestroyWindow` /
  `GetModuleHandleW` 声明，此前自 `@cImport` 移除后即失配）。

### 7.5 EraSync 内核 Windows 部署修复（2026-09-11，待真机验证）

现象：Windows 任意文件播放闪退；Linux 正常。根因是**打包缺陷而非内核运行时缺陷**：

- `app/core/audio-engine/build.zig` 同时安装静态库与动态库，Windows 下二者基名相同
  （`archoera_kernel.lib`）；动态库 install 在后，其 **DLL import lib 覆盖了静态库**。
- `build_windows.bat` 正是链接该 `zig-out\lib\archoera_kernel.lib`（import lib）→
  `archoera_mediaengine.dll` 产生对 `archoera_kernel.dll` 的**加载期硬依赖**。
- 而 Zig 把 DLL 装在 `zig-out\bin\archoera_kernel.dll`，scanner csproj / CMake 却按
  `lib/` 找 → DLL 从未进入 bundle → 播放首帧 `DynamicLibrary.open(mediaengine)`
  失败即闪退（与具体文件无关）。

修复：`build_windows.bat` 从 `zig-out\bin` 拷 DLL 到引擎 `build\`；`app/windows/
CMakeLists.txt` 将其装到 **exe 根**（Windows 加载器按 exe 目录解析依赖，scanner
`KernelMetadata` 亦按 `AppContext.BaseDirectory` 查找）；scanner 两个 csproj 的
Windows DLL 源路径 `lib`→`bin`；`KernelMetadata.LocateLibrary` 开发树回退路径按平台
取 `bin`/`lib`。注：Windows 静态库当前不含 compiler-rt（`___chkstk_ms` 等），故
Windows 走 DLL 而非静态链接。

## 8. 风险与对策

| 风险 | 对策 |
|---|---|
| 自研 D-Bus 编组 bug（`a{sv}` 变体） | 类型面收敛为 9 种；编组往返单测；P2 以 `playerctl`/`busctl` 实测对拍 |
| SMTC 需要 STA/apartment 差异 | 全部 WinRT 调用固定在 IO 线程 MTA 初始化；`GetForWindow` 在该线程执行 |
| objc_msgSend ABI 直调脆弱 | 仅用签名固定的少数字面（消息发送 id/SEL + 对象/整型参数）；`dispatch_async` 统一主线程；P4 真机验收 |
| D-Bus 断连（登录会话重启） | IO 线程检测 EOF → 重连一次 → 失败发 `APL_EVENT_BACKEND_STATE(lost)`（Dart toast + 回落 Noop），恢复后重试 inhibit/media 注册 |
| WndProc 子类化时序（Flutter 重建窗口/多窗口） | 子类化在 `apl_media_set_window` 时执行并保存原链；Dart 侧窗口销毁/重建时重传句柄；不吞消息保证零回归 |
| X11/Wayland 差异 | GTK/GDK 统一覆盖（GDK 抽象两会话）；GTK 不可用时才不置位图 → 回退 window_manager |
| 熄屏事件误报（Win console display state 与锁屏非严格对应） | 语义定义为「显示器电源状态」，power_saver 档位判定保持宽松（等同既有 screenOff 兜底帧率） |
| 双库并存体积 | 独立小库（预估 <300KB/平台），打包脚本一项拷贝；不做进 mediaengine（生命周期/职责分离） |
| FFI 回调生命周期 | `NativeCallable.listener` 持有至 `apl_set_event_callback(NULL)` + `close()`，防止 isolate 退出后野回调 |

## 9. 决策记录

1. **语言 = Zig、形态 = 同进程 dylib、通信 = extern struct + C ABI**（2026-09-10，
   用户）：零 JSON、零子进程、`dart:ffi`；工具链与 audio-kernel 同源，单 `build.zig`
   交叉编译三平台；
2. **职责切分**（2026-09-10，用户）：Dart 只调用统一接口；平台探测、转发、系统请求、
   事件回传全部在 Zig；
3. **范围 = Windows/Linux/macOS**（2026-09-10，用户）；Android/iOS 不在本期；
4. **Linux D-Bus 自研**（2026-09-10，建议采纳）：避免 FFI/Dart 包双轨；仅实现
   ScreenSaver + MPRIS 所需子面，不做通用库；
5. **后台播放不在本层**（facade §7.1）：托盘 + 引擎线程既有链路，不动；
6. **Power 能力三平台全覆盖**（2026-09-10，用户）：休眠抑制与熄屏检测不作为 Linux
   专属——Windows（SetThreadExecutionState + PowerSettingRegisterNotification）、
   macOS（beginActivity + NSWorkspace 通知）同为 P3/P4 必做项，能力位图三平台恒置位；
7. **执行失败显式告警**（2026-09-10，用户）：能力缺失 = Noop 静默降级；调用失败
   （`APL_ERR_BACKEND` 等）= Dart UI toast 显式警告。告警分级：影响用户可感知能力的
   （休眠抑制、媒体会话）必须 toast；后台优化类（熄屏/窗口事件订阅）静默回落 +
   debug 日志；
8. **窗口状态检测 Zig 接线**（2026-09-10，用户）：`APL_CAP_WINDOW_STATE` +
   `SystemWindow`，Win/macOS 子类化 WndProc / NSWindow 通知；Linux 走 GTK/GDK
   （会话检测 + 统一模式，X11/Wayland 皆覆盖）；
9. **MPRIS `CanGoNext/CanSeek` 首期恒真**（2026-09-10，建议采纳）：命令落空由 Dart
   忽略，省队列状态推送。
