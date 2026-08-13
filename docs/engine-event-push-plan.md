# 引擎事件推送与降频协商规划

> 状态：规划稿 · 2026-08-12
> 定位：下一代音频引擎通信模型——从「Dart 定时轮询」改为「C 主动推送 + 降频协商协议」，
> 从源头削减 Dart 侧固定负载，避免降频切换时的请求过载、崩溃与溢出。

---

## 1. 背景与动机

### 1.1 现状链路

```
C 引擎线程（按音频位置，每 50ms 1 帧 position 事件）
        │  ev_enqueue（线程安全 FIFO，有界 512 条，满则丢弃）
        ▼
Dart 侧 Timer.periodic(50ms) 轮询 pollEvent → while 排空 FIFO → 逐条 JSON 解析
        │
        ▼
PlaybackNotifier._onEngineEvent → state.copyWith(position) → _pollSpectrum()
```

关键事实：
- C 侧事件**按音频位置**产生（`player.c` 的 `POSITION_INTERVAL_MS 50`，`step = sample_rate / (1000 / interval)`），不是定时器；
- Dart 侧是**固定 50ms 轮询**（`audio_engine_process.dart` 的 `_pollInterval`），无论 FIFO 有无事件，每次轮询都是一次 FFI 调用；
- 事件 FIFO 有界（`EV_CAP 512`），满则静默丢弃（当前可接受，因为事件量低）。

### 1.2 现存降频层次（已有）

| 层次 | 机制 | 目标 |
|---|---|---|
| 渲染帧节流 | `PowerSavingFrameBinding` 覆写 `scheduleFrame`，最小化 5FPS / 失焦、熄屏 1FPS | 压 GPU 渲染开销 |
| FFT 取帧节流 | `_pollSpectrum` 时间戳节流，100ms 基线 / 节能 300ms | 压 FFT 磁盘 IO + 计算 |
| FFT 异常帧防御 | `_finite()` 归一化 NaN/Inf/负值 | 防绘制崩溃 |

### 1.3 问题：Dart 侧仍有固定负载

现有降频都发生在 Dart 侧（渲染层合并、取帧节流），但 **C 引擎仍然每 50ms 推事件、Dart 仍然每 50ms 轮询**：

1. **Dart 每 50ms 处理一条 position 事件**：`state.copyWith` → 通知订阅者 → 触发渲染请求（渲染请求虽被帧节流合并，但 Dart 逻辑照跑）；
2. **Dart 每 50ms 固定轮询一次**：纯固定开销（FFI 调用 + FIFO 排空 + JSON 解析），与事件多少无关。

降频期间窗口不可见，position 事件对 UI 无实际意义，却持续消耗 Dart CPU。这就是「对 C 降频」要解决的问题。

---

## 2. 目标

1. **砍掉 Dart 的定时轮询**，改为 C 主动推送（事件驱动唤醒 Dart，无事件即零开销）；
2. **保留双向按需通信**（Dart → C 命令通道不变：play/pause/seek/set_volume/降频信号等）；
3. **正常态 50ms 推送**，行为与现在等价；
4. **降频协商协议**：Dart 发降频信号 → C 主动与 Dart 协商下一帧间隔 → 按协商节奏推送；
5. **档位任意切换都能协商对齐**，不出现请求过载、FIFO 溢出、位置回退崩溃。

---

## 3. 设计：C 主动推送（去轮询）

### 3.1 事件通道改造

保留线程安全 FIFO 作为事件缓冲（有界），但**去掉 Dart 侧 50ms 轮询 Timer**，改为「唤醒式排空」：

- Dart 侧创建 `ReceivePort`，通过 `NativeCallable.listener`（`dart:ffi`）把端口句柄传给 C 引擎；
- C 引擎线程每次 `ev_enqueue` 后，用 `Dart_PostCObject` 向该端口投递一个空通知（或「新事件计数」）；
- Dart 侧被唤醒后一次性排空 FIFO（沿用现有 `while (true) pollEvent` 逻辑），无事件时不执行任何轮询逻辑；
- `Timer.periodic` 与 `_drainEvents` 的轮询驱动整体移除。

效果：事件到达才消费，空闲时 Dart 侧零轮询负载。这依赖 Dart 原生端口能力（FFI 层已具备，跨 Win/macOS/Linux 一致）。

### 3.2 控制命令通道不变

Dart → C 的 `sendCommand`（JSON 行 → 命令 FIFO）继续作为双向按需通信的唯一控制通道，**不做改动**。降频信号也走这条通道。

---

## 4. 降频协商协议

### 4.1 档位定义

| 档位 | 事件间隔 | 对应场景 | 说明 |
|---|---|---|---|
| `normal` | 50ms | 前台正常 | 与现状等价 |
| `minimized` | 500ms | 窗口最小化 / 托盘隐藏 | 2Hz 事件保底（进度兜底） |
| `unfocused` | 1000ms | 窗口失焦 / 屏幕关闭（锁屏） | 1Hz 事件保底 |

档位映射复用 `PowerSaverService._reason` 的现有判定（window_manager 窗口事件 + Linux D-Bus `ActiveChanged`）。

### 4.2 协商流程

**降频（Dart → C）：**

1. Dart 侧 `PowerSaverService._apply()` 判定档位变化；
2. Dart 经 `sendCommand('set_event_interval', {'interval_ms': 500})` 发出降频信号；
3. C 侧 `handle_command` 收到后：更新 `player.position_interval_ms`（运行期字段，替代编译期常量），并**立即向 Dart 回执一次协商结果**（如 `{"type":"event_interval","interval_ms":500}`）；
4. Dart 收到回执后确认档位生效，后续 position 事件按新间隔到达。

**恢复（C → Dart 同理）：**

1. Dart 发 `set_event_interval {'interval_ms': 50}`；
2. C 回执确认；
3. Dart 侧主动发一次 `get_status` 拉取精确位置（命令已存在），进度条/歌词立即对齐，无需等待下一个 position 事件。

**要点**：档位切换以「C 回执」为准，Dart 不假设切换已生效——双方始终以协商结果同步节奏，避免半切换状态下的请求过载与事件堆积。

### 4.3 防溢出与丢帧策略

- **FIFO 有界（512 条）**：降频时事件量低，不会满；恢复 50ms 前若理论上有积压（极小概率），position 事件语义为「最新值有意义」——C 侧 `ev_enqueue` 对 position 事件做**「只保留最新」合并**（队列中已有 position 事件时覆盖而非追加），从源头消除积压与恢复突发；
- **降频期间**：间隔拉长后，中间帧的绘制请求由 Dart 侧渲染帧节流（PowerSavingFrameBinding）与 FFT 取帧节流（`_pollSpectrum`）兜底，本协议只负责**事件源头减量**，三层不冲突；
- **协商失败兜底**：C 回执超时（异常场景）时，Dart 侧降级为「按当前档位本地节流取帧」，不阻塞播放。

### 4.4 位置对齐

降频期间 UI 不可见，position 精度不敏感；恢复前台时用一次 `get_status` 精确对齐（见 4.2），歌词/进度条无感知跳变。

---

## 5. 改动点清单

| 文件 | 改动 |
|---|---|
| `app/core/audio-engine/src/player.c` | `POSITION_INTERVAL_MS` 编译期常量 → 运行期字段 `position_interval_ms`（默认 50）；`step` 计算引用该字段 |
| `app/core/audio-engine/src/mediaengine_lib.c` | 新增命令分支 `set_event_interval`（解析 `interval_ms` 写入 player 字段）；新增 `event_interval` 回执事件；`ev_enqueue` 对 position 事件做「只保留最新」合并；新增 `Dart_PostCObject` 唤醒投递（事件入队后） |
| `app/core/audio-engine/include/archoera_mediaengine.h` | 新增导出：事件监听端口注册（如 `archoera_mediaengine_attach_event_port`） |
| `app/lib/services/playback/engine_bindings.dart` | 新增 FFI 绑定：事件端口注册 |
| `app/lib/services/playback/audio_engine_process.dart` | 移除 `Timer.periodic` 轮询，改为 native port 唤醒排空；保留 `sendCommand` 通道；新增 `setEventInterval(ms)` 快捷命令 |
| `app/lib/services/power/power_saver.dart` | `_apply()` 按 `_reason` 联动引擎 `setEventInterval`（minimized→500 / unfocused、screenOff→1000 / none→50）；收到回执后置 `get_status` 对齐 |
| `app/lib/services/playback/playback_notifier.dart` | 处理 `event_interval` 回执事件；`_fftPollIntervalMs` 与引擎档位联动（可选，取帧间隔跟随） |

---

## 6. 风险与权衡

| 风险 | 应对 |
|---|---|
| native port 唤醒依赖 FFI 跨线程投递，三平台一致性需验证 | Win/macOS/Linux 均由 Dart VM 提供 `Dart_PostCObject`，行为一致；先在 Linux 验证，再全平台回归 |
| 移除轮询后若唤醒信号丢失，事件断流 | 保留低频兜底（如 1s 健康检查轮询，仅用于异常恢复，正常路径零开销）——实现时按需取舍 |
| 档位切换竞态（回执与事件交错） | 以回执为准的协商制；position 事件本身幂等（绝对位置），乱序无副作用 |
| 改动跨 C 与 Dart 两层 | 建议拆两步落地：第一步「源头降频」（运行期间隔 + 命令 + PowerSaver 联动，改动小）；第二步「去轮询推送」（native port 唤醒） |

## 7. 验证计划

1. Linux 本地完整编译（C 引擎 + Flutter）验证链路；
2. 正常播放：50ms 事件节奏与现状等价（进度条、FFT、歌词无回归）；
3. 最小化 / 失焦 / 熄屏：事件间隔切至 500ms / 1000ms，`power_saver` 日志确认回执；
4. 恢复前台：`get_status` 对齐，进度与真实位置一致；
5. 快速切换档位（50→1000→50→500→50）：无崩溃、无 FIFO 溢出、无位置回退冻结；
6. 三平台（Win / macOS / Linux）CI 构建验证。
