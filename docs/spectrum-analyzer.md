# 频谱分析器 v2 — 设计规格、实现与验收

> 状态：**已实现并验收（2026-11-04）**。P0（取帧节奏 / 前端插值）与 v2 内核、
> 引擎 50ms 事件推送、前端纯接收端均已完成；P4 显示增强为可选后续项，未纳入
> 本次 v2 交付。
>
> 范围：桌面端频谱分析链路（C 引擎 / Zig 内核 / Dart 接收端 / Flutter 渲染）。
> 不含歌词、背景与列表页。
>
> ⚠ **破坏性更新**：App 播放路径不保留旧拉模式与旧 `libfft.so` ABI 兼容。
> 频率范围、数据契约、引擎事件与前端接收方式均按 v2 直接替换；旧播放路径实现
> 删除，不提供兼容层。
>
> 关联：`docs/architecture.md` §10.1、`docs/audio-kernel-zig.md` §14、
> `docs/audio-memory-playback.md`、`docs/player-render-optimization.md` §4.3、
> `docs/runtime-resource-optimization.md`。

---

## 1. 背景与问题

频谱部分一直是**独立实现**（`src/fft.c` / `libfft.so`），不依赖 FFmpeg 或其它
第三方 DSP。当前链路是「Dart 按播放位置拉 PCM 窗口 → FFI 做 FFT → UI 插值」，
存在以下结构性问题：

| # | 问题 | 影响 |
|---|---|---|
| 1 | 取帧被节流到 100ms（10Hz），失焦时跟随引擎事件降到 1000ms | 鼓点/瞬态跟不上，画面发肉 |
| 2 | 单个 2048 点 FFT 在 48kHz 下是 23.4Hz/bin，而 80Hz 处对数带只有 ~2Hz | 最低十几个带共用同一个 bin，低频块状、不跟手 |
| 3 | 幅度按 `2·|X|/N` 定标，比 Chromium/SPlayer 高 6dB | 动态余量小，条形容易顶满 |
| 4 | 归一化后 `≤0.04` 直接清零 | 小信号突然消失/冒出，收尾不自然 |
| 5 | FFT 在 UI isolate 同步执行（文件模式还有同步磁盘读） | 提频有卡帧风险，无法安全做到 20Hz |
| 6 | UI 既是消费者又是生产者（拉模式） | 前端承担 FFI/IO/线程调度，违背「UI 只做调度」 |

P0 已修掉 1 和「插值窗口写死 50ms」；本规格处理 2–6。

## 2. 目标与非目标

### 2.1 目标

1. **频率范围扩展**：默认 **40Hz – 16kHz**、128 个对数带（约 14.5 band/oct）。
2. **多分辨率分析**：低频用长窗、高频用短窗，解决低频 bin 不足。
3. **20Hz 稳定推送**：引擎侧 50ms 节奏，不受 UI 帧率/焦点影响；性能模式可整体关闭。
4. **UI 只做接收端**：前端不再拉 PCM、不再调 FFI、不做 FFT；只消费事件并渲染。
5. **不拖慢冷/热启动与线程池**：频谱线程独立、懒初始化、零每帧分配、可丢弃。
6. **破坏性更新**：不保留旧拉模式/旧 ABI 兼容；App 播放路径不再使用
   `libfft.so` 的 `fft_*` 与 `fft_bindings.dart`，v2 唯一入口是内核
   `zk_dsp_spectrum_*`；旧 `libfft.so` 仅留给未迁移的 CLI/测试。

### 2.2 非目标

- 不把整条链路换成 CQT/VQT（收益/成本不划算，见 §4.2）。
- 不做离线频谱分析/导出。
- 不改歌词、背景、播放页布局。
- 不要求 UI 端做任何 DSP（显示平滑除外）。

## 3. 总体架构

v2 链路（已落地，事件推送）：

```
解码 / 播放位置
   │
   ├─ 流式模式：最近 PCM 环形缓冲（约 0.5s，按块起始位置写入）
   ├─ 文件模式：stream.pcm（独立 FILE* + 增量索引）
   └─ 内存模式：进程内 PCM 块列表
            │
            ▼
   EraSpectrumService（引擎独立线程，50ms）
     ├─ 多分辨率 FFT（8192 低频 + 2048 高频）
     ├─ 128 对数带 + dB + 软膝
     └─ 频谱通量节拍
            │  EraSpectrumFrame（128×2 个 [0,1] + 元数据）
            ▼
   引擎事件（JSON / FFI 回调）
            │  {"type":"fft", ...}
            ▼
   Dart PlaybackNotifier（只解析事件 → state.fft）
            │
            ▼
   SpectrumView / CustomPainter（只做插值与显示平滑）
```

关键点：

- **生产者是引擎**，不是 UI。UI 不再持有 `PcmAnalyzer` / `FftAnalyzer`。
- **取的是「已播放位置」**，不是解码位置。解码可快于实时，频谱必须跟耳朵。
- **事件可丢**：频谱是装饰性数据，消费端慢时丢弃旧帧，绝不反压音频线程。
- **表按会话建一次**：窗、旋转因子、频带边界按 `(sample_rate, fft sizes,
  range)` 在首次 `set_fft` 时构建；同会话暂停/恢复只 `reset` 状态，不重建。

### 3.1 与解码后端的关系（标准 FFmpeg / EraAudio 共用）

频谱服务挂在 **MediaEngine 层**，位于解码后端之上，**不调用任何 FFmpeg API**：

| 解码后端 | PCM 产物 | 频谱读取方式 |
|---|---|---|
| 标准 FFmpeg（Stable） | `on_pcm_out` → 内存块列表 / `stream.pcm` | 按播放位置读块/文件 |
| EraAudio（Zig 内核） | 同上（`on_pcm_out` 是同一条回调） | 同上 |

- 两个后端都经 `pipeline_set_pcm_out_cb` 输出 PCM；频谱服务只依赖这个回调的
  产物，因此 **切换引擎不影响频谱**。
- **不使用 FFmpeg 的频谱能力**：不引入 `libavfilter/showspectrum`、`av_fft`、
  `swr` 等；FFmpeg 只负责解码，频谱是独立实现（`kernel/dsp/spectrum.zig`）。
- `pipeline.c` 里已有的 `fft_process_multi` 仅服务 CLI/流式推送，**不是 App 的
  频谱源**；App 统一走 `EraSpectrumService`。
- 读取位置 = **播放位置**（`ma_sound_get_cursor_in_pcm_frames` /
  `player_stream_played_ms`），不是解码回调的 `position_ms`；FFmpeg 解码可快于
  实时，按解码位置取窗会「超前」。
- 位置换算：`abs_ms = 会话起点 + 播放器已播时长`（与 `position` 事件同一坐标系）；
  不能直接用相对的设备游标，否则内存块/文件索引会错位。
- 数据源按模式选择（都来自 `on_pcm_out` 的解码 PCM，**不是** SegStore 的编码源）：
  - 流式模式（App 默认）：引擎内最近 PCM 环形缓冲（约 0.5s，按块**起始**
    位置写绝对样本号，按播放位置回退 `frames`）；
  - 内存模式：引擎内部 `mem_window`（复用现有块列表，不再经 Dart FFI）；
  - 文件模式：`stream.pcm` 块索引 + 独立 `FILE*`（`fread`/`fseeko`，C 侧
    增量扫描，等价于旧 `PcmAnalyzer`，但运行在频谱线程）；
  - store 会话：同样走 `mem_window` / `stream.pcm`（SegStore 只供解码器作
    AVIO 输入，不含解码 PCM）。
- **分层**：源适配（`mem_window` / `stream.pcm`）与线程/事件在 C 壳
  （`mediaengine_lib.c` 或新 `spectrum_service.c`）；纯计算在
  `kernel/dsp/spectrum.zig`。核心不做 I/O、不建线程、不依赖 FFmpeg。
- **服务壳语言**：优先 C（直接复用现有源/事件队列，避免跨语言生命周期与启动
  开销）；后续可整体移入 Zig，保持 `EraSpectrumFrame` 契约不变。
- seek / 音质切换 / `mediaengine_stream_rebuild`：`mem_epoch` 或文件长度回退
  触发 `reset()`，丢弃旧帧；不重建解码器。
- **`set_fft` 语义变更（破坏性）**：App 的 `set_fft {enabled}` 改为启停
  `EraSpectrumService`（事件推送），不再切 `pipeline_set_fft_enabled`；CLI 的
  `--fft` 仍走 `pipeline` 内的 `fft_process_multi`（v2 核心、按解码位置推送），
  两者互不复用、互不干扰；CLI 输出同样按 40–16kHz/128 带变更（破坏性）。
- 启动/线程：`set_fft` 只启停独立频谱线程，不触碰 FFmpeg 的 decode worker 池；
  频谱关闭时零额外工作。

### 3.2 标准 FFmpeg 引擎的接入点（逐步）

1. `mediaengine_create` 选 FFmpeg 后端 → `pipeline_create` 解码。
2. `pipeline_process` 每块 PCM 调 `on_pcm_out(pcm, samples, ch, decode_pos_ms)`。
3. `on_pcm_out`：流式模式写最近 PCM 环 + 设备；内存模式 `mem_append`；
   文件模式写 `stream.pcm`。**这一步对 FFmpeg / EraAudio 完全一致**；
   SegStore 只是在线源的编码输入，不是频谱源。
4. App 发 `set_fft {enabled:true}` → 启动 `EraSpectrumService`（独立线程）。
   **不再**调用 `pipeline_set_fft_enabled`。
5. 频谱线程每 50ms：
   - 读**播放位置** `abs_ms = 会话起点 + 已播时长`；
   - 按模式取窗：流式环形缓冲 / `mem_window` / `stream.pcm` 增量索引；
   - `spectrum.zig` 多分辨率分析；
   - `ev_enqueue_fft({"type":"fft",...})`（独立最新帧槽，可丢）。
6. Dart 事件循环解析 → `PlaybackState.fft` → `SpectrumView` 渲染。

关键约束：

- 第 3 步不依赖 FFmpeg 的数据结构；频谱只认 `on_pcm_out` 的产物。
- 第 5 步不用解码回调的 `position_ms`（FFmpeg 可能已解码到前面），只用播放位置。
- 第 5 步的 `mem_lock` 用 `try_lock`，拿不到就跳过本帧；不在解码线程上做 FFT。
- 第 4 步只启停频谱线程，不重建解码器、不向 decode worker 池提交任务。

## 4. 分析算法 v2

### 4.1 频率范围与频带

- 默认 `MIN_HZ = 40`、`MAX_HZ = 16000`、`BINS = 128`。
- 频带边界按对数等分：

```text
f_i = MIN_HZ * (MAX_HZ / MIN_HZ)^(i / BINS),  i = 0..BINS
```

- 40Hz 处带宽约 1.9Hz，1kHz 处约 48Hz，16kHz 处约 766Hz。
- 范围可配置；引擎事件使用同一套 v2 配置（40–16kHz），不再保留 80–2000Hz
  的旧兼容配置；旧 `libfft.so` 不参与 v2。

> 为什么不是 20Hz：大多数内容在 20–40Hz 能量很少，小音箱也放不出；40Hz 已覆盖
> kick/bass 主体。为什么不是 20kHz：16kHz 足够表现「空气感/镲片」，再往上多是
> 噪声与超声，且 44.1kHz 源的 Nyquist 只有 22.05kHz。

### 4.2 多分辨率 FFT

| 频段 | FFT 点数 | 48kHz 下 bin 宽 | 窗口时长 | 用途 |
|---|---|---|---|---|
| 低频 40–300Hz | 8192 | 5.86Hz | 170.7ms | 低音、kick、贝斯 |
| 高频 300–16000Hz | 2048 | 23.4Hz | 42.7ms | 人声、吉他、镲片、瞬态 |

- 跳距固定 **50ms**（20Hz 推送）。
- 交叉区 250–350Hz 做线性 crossfade，避免拼接处出现凹口/台阶。
- 采样率 44.1/48/96kHz 均使用固定点数；96kHz 下窗口更短，44.1kHz 下略长，均在
  可接受范围。若未来需要严格固定窗口时长，可按采样率选择点数（配置项）。
- 低频 8192 点窗口的中心延迟约 85ms；低频瞬态本来就慢，视觉上可接受。

> 为什么不上 CQT：CQT 的 `f/Δf` 恒定，音乐上最理想，但计算量、延迟和实现复杂度
> 都明显高于「两级 FFT + 对数聚合」。对装饰性频谱，多分辨率 FFT 能拿到大部分收益。

### 4.3 窗与幅度定标

- **Blackman 周期窗**：

```text
w[n] = 0.42 - 0.5·cos(2πn/N) + 0.08·cos(4πn/N)
```

- 相干增益 `CG = 0.42`。
- 单边幅度定标：

```text
mag[k] = 2·|X[k]| / (N·CG)
```

- 校准目标：**0dBFS 正弦（落在 bin 中心）→ 1.0（0dB）**。
- 不再使用 `2/N`（旧实现比 Chromium/SPlayer 高 6dB）。
- 峰值 `mag` 夹到 `[0, 1]`，但不在分析层做硬清零（见 §4.5）。

### 4.4 频带聚合

对每个对数带 `[f_lo, f_hi)`：

1. 找到与之相交的 FFT bin 区间 `[b_lo, b_hi)`。
2. 若 `b_hi - b_lo >= 1`：取**平均功率**再开方：

```text
P_band = mean(mag[k]^2 for k in [b_lo, b_hi))
band   = sqrt(P_band)
```

3. 若频带比一个 bin 还窄（低频常见）：在**对数频率轴**上对相邻 bin 的功率做
   线性插值，取频带中心处的值，避免多个相邻带共用同一个 bin 导致块状。

- 高频宽带不会因为 bin 多而天然更高（平均功率抑制了带宽偏差）。
- 可选的显示倾斜（默认关，A/B 后再定）：`+1.0 dB/oct above 1kHz`，用于提亮
  「空气感」。不做完整 A-weighting（会把 50Hz 压掉约 30dB）。

### 4.5 dB 映射与软膝

```text
db = 20·log10(band + 1e-12)
t  = clamp((db + 72) / 72, 0, 1)        // -72dB → 0，0dB → 1
gate = clamp(t / 0.06, 0, 1)            // 底部 6% 做软膝
t  = t * gate² * (3 - 2·gate)           // smoothstep 淡入
```

- 动态范围从旧 `-60..0` 扩到 `-72..0`，给低电平细节留空间。
- 去掉 `≤0.04` 硬清零；小信号连续淡出到 0，不再「啪」地消失。
- 软膝只影响最底部约 4.3dB（-72..-67.7dB），不影响主体动态。

### 4.6 时间平滑与峰值

- **分析器输出瞬时值**；显示平滑仍由前端负责（P0 已按 `dt` 归一化）。
- 原因：UI 的刷新率/降档策略只有前端知道；分析器不应假设帧率。
- 保留可选的分析器侧 EMA（`fft_set_smoothing`，默认 0），供 CLI/其它消费者。
- 峰值保持（可选导出）：`peak = max(peak·decayPerFrame, band)`，衰减按
  **20dB/s** 换算到实际帧间隔，而不是旧的「每帧 1%」。

### 4.7 节拍 / 瞬态

用**对数谱通量**替代当前的三频段能量比：

```text
flux[t] = Σ_k max(0, log(1 + band[t][k]) - log(1 + band[t-1][k]))
```

- 自适应阈值：最近 43 帧（约 2.15s @20Hz）的中位数 × 1.5 + 0.02。
- 冷却：100ms（2 帧 @20Hz）。
- 强度：`clamp((flux - threshold) / (peak - threshold), 0, 1)`。
- 仍通过 `fft_take_beat_strength` / 事件字段 `beat` 输出，前端契约不变。

> 参考：Dixon 2006 的 onset detection function；SuperFlux（Böck & Widmer 2013）
> 的「最大值滤波 + 通量」思路。对持续音/电子音比能量比更稳。

### 4.8 立体声与多声道

- L/R 独立分析，输出 `ldata` / `rdata` 各 128 个 `[0,1]`。
- 多声道下混沿用 ITU-R BS.775（与现实现一致）：

```text
1ch: L = R = s0
2ch: L = s0, R = s1
3ch: L = s0 + 0.7071·C, R = s1 + 0.7071·C
4ch: L = s0 + 0.7071·BL, R = s1 + 0.7071·BR
5ch: L = s0 + 0.7071·C + 0.7071·BL, R = s1 + 0.7071·C + 0.7071·BR
6ch: 同 5ch，LFE 不入下混
```

- 单声道时 L=R；5.1 的 LFE 不参与，避免低频能量虚高。

## 5. 线程、启动与性能

### 5.1 线程模型

```
PlayerCtx / MediaEngine
   ├─ 解码线程（现有）
   ├─ 播放/设备线程（现有，miniaudio）
   └─ EraSpectrumService 线程（新增，独立）
         每 50ms：
           1. 读原子播放位置 pos_ms
           2. source.read_window(pos_ms, N, L, R)
           3. 多分辨率 FFT + 频带 + dB
           4. emit(frame)  // 可丢
           5. sleep 50ms（10ms 分片检查 stop）
```

- **不占用解码 worker 线程池**；频谱线程是独立线程。
- **不在音频回调里做 FFT**；回调只更新原子位置/写入环形缓冲。
- **不阻塞**：`read_window` 只做内存拷贝或文件读；事件发送失败/积压直接丢帧。
- **锁纪律**：内存块列表的 `mem_lock` 用 `try_lock`，拿不到就跳过本帧；流式环
  用短锁拷贝窗口；文件读取器用独立锁。持锁只做一个窗口的只读拷贝（≤8192
  样本），绝不跨 FFT/事件发送持锁。
- **停止可控**：stop flag 每 10ms 检查一次，`join` 在 ~10ms 内返回；不在音频线程
  上 `join`。
- 暂停/停止：停线程或跳过发送；恢复时 `reset()`，避免把暂停前的旧帧推上去。

### 5.2 冷/热启动

| 场景 | 约束 | 做法 |
|---|---|---|
| 引擎冷启动（频谱关） | **零额外工作** | 不创建线程、不建表、不分配 |
| 引擎冷启动（频谱开） | 增量 < 1ms，且不占主线程 | 首次 `set_fft enabled` 时懒建（当前每会话一次；建表约 <1ms） |
| 切歌/热启动 | 增量 < 0.1ms | 复用会话内已建表；只 `reset()` 状态 |
| 采样率变化 | 重建而非错用 | 采样率变化时销毁旧服务并按新率重建 |

- 窗表、旋转因子表、频带边界表：创建时一次构建；`reset` 只清帧间状态。
- 每帧缓冲（输入、复数工作区、输出、通量历史）：创建时一次性分配，之后零分配。
- 禁止静态构造函数/全局初始化器做重活；所有初始化显式、懒执行。
- 进程级跨曲目表缓存是后续优化项；当前建表开销已低于 1ms，不阻塞冷启动。

### 5.3 线程池约束

- 频谱线程**不提交**任何任务到解码 worker 池。
- 解码 worker 不得等待频谱线程；频谱线程只读已解码数据。
- 流式模式环形缓冲有界（约 0.5s），超出即覆盖最旧样本。
- 文件模式读取有界（单次 ≤ 64KB），失败/慢盘直接跳过该帧。
- 内存模式只做块列表快照/拷贝，不持有长锁。
- 关闭顺序：先停频谱线程，再释放 PCM 源；避免 use-after-free。

### 5.4 预算（48kHz，20Hz 推送）

| 项 | 估算 |
|---|---|
| 8192 点 FFT ×2 声道 | ~21 万 butterfly/帧 |
| 2048 点 FFT ×2 声道 | ~4.5 万 butterfly/帧 |
| 合计 | ~5.1M butterfly/s，约 50 MFLOP/s |
| CPU | 现代 x86 < 1% 单核；ARM < 3% |
| 内存 | 表 + 缓冲 < 512KB |
| 事件 | 128×2 个 8-bit 整数 + 元数据 ≈ 1.2KB/帧，24KB/s |
| UI 解析 | < 0.2ms/帧（主 isolate） |

## 6. 数据契约

### 6.1 引擎事件

```json
{
  "type": "fft",
  "seq": 42,
  "interval_ms": 50,
  "sample_rate": 48000,
  "bins": 128,
  "min_hz": 40.0,
  "max_hz": 16000.0,
  "beat": 82,
  "ldata": [0, 31, ...],
  "rdata": [0, 26, ...]
}
```

- `ldata` / `rdata`：128 个 **8-bit 量化整数 `[0,255]`**，对数频带，
  40–16000Hz；前端除以 `255` 还原 `[0,1]`（浮点值仍按原值解析，便于调试）。
- `beat`：0–255 的脉冲强度，前端除以 `255` 还原 `0..1`；无脉冲为 0。
- `seq`：单调递增；UI 可检测丢帧/重启。
- `interval_ms`：生产端目标间隔；当前引擎固定 50ms，前端按该值插值（契约保留
  其它档位，便于后续节能降频）。
- 事件可丢；UI 以最新一帧为准。
- 事件走**独立「最新帧」槽**（`ev_fft`，2048B），不占用 511B 的常规事件
  队列；旧帧被新帧覆盖，`poll_event` / `wait_event` 优先交付常规事件，其次
  交付最新频谱帧。

### 6.2 `FftFrame`（Dart）

```dart
class FftFrame {
  final List<double> ldata;   // 128, [0,1]
  final List<double> rdata;   // 128, [0,1]
  final double beatStrength;  // 0..1
  final int intervalMs;       // 生产端目标间隔
  final int seq;              // 单调序号
  final int minHz;            // 40
  final int maxHz;            // 16000
}
```

- 事件解析时创建新 List；**不复用**跨事件缓冲（避免 UI 持有被下一帧覆盖的数据）。
- `PlaybackState.fft` 只由 `EngineFft` 事件更新。

### 6.3 `libfft.so`（旧 ABI 不再属于 App 播放路径）

- App 播放路径**不再加载** `libfft.so`，也不再使用 `fft_create` 等旧 `fft_*`
  ABI；v2 的唯一对外计算入口是内核 C ABI `zk_dsp_spectrum_*`
  （`include/kernel_bridge.h`）。
- 源码树仍保留 `src/fft.c` → `libfft.so` 的构建，供尚未迁移的 CLI/外部集成
  使用；它**不是** v2 契约，行为仍为旧的 80–2000Hz / -60..0 实现。
- 需要 v2 的消费者应直接链接/加载内核 `zk_dsp_spectrum_*`，不要依赖旧
  `fft_*`。这是**破坏性更新**：不承诺旧版调用方二进制/源码兼容；CHANGELOG
  与发布说明必须显式标注。

## 7. 前端重构

### 7.1 职责边界

| 层 | 职责 |
|---|---|
| 引擎 | 取窗口、FFT、频带、dB、节拍、50ms 推送 |
| Dart `PlaybackNotifier` | 解析 `fft` 事件 → `PlaybackState.fft` |
| `SpectrumView` / Painter | 帧间插值、攻/放显示平滑、绘制 |
| `spectrum_timing.dart` | 纯时间学（P0 已落） |

### 7.2 删除

- `_pollSpectrum()`、`PcmFftSource`、`PcmAnalyzer`、`MemoryPcmAnalyzer`、
  `fft_bindings.dart` 从 App 播放路径**直接删除**，不保留 A/B 回退。
- `fft_bindings.dart` / `pcm_analyzer.dart` 文件可保留给未迁移的 CLI/测试，
  但 App 播放路径不得导入；`libfft.so` 继续按旧实现构建，不参与 v2。
- `EnginePaths.libfftPath` 可移除，或仅留给 CLI/测试。
- 旧拉模式相关测试同步替换为 v2 事件/核心测试。

### 7.3 渲染端

- `SpectrumView` 只 `watch` `state.fft`，不触发任何 FFI/IO。
- 插值/攻/放继续用 `spectrum_timing.dart`（按 `intervalMs` 与 `dt` 归一化）。
- 可选显示增强（A/B 后决定，默认关）：
  - 全局慢 AGC（约 2–5s 时间常数），让小音量歌曲也有内容；
  - `norm^γ`（γ≈0.8–1.0）提亮小信号；
  - 高频倾斜；
  - 峰值保持线。

## 8. 实施阶段

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P0 ✅** | 20Hz 取帧、动态插值、攻/放 dt 归一化 | `flutter test` 全绿 |
| **P1 ✅** | v2 纯计算核心（优先 Zig `kernel/dsp/spectrum.zig`；C 参考并行） | 黄金单测 + 与 C 对拍 |
| **P2 ✅** | 引擎 `EraSpectrumService` + `fft` 事件 + Dart 接收端（直接切换） | 20Hz 稳定、UI 无 FFI |
| **P3 ✅** | 移除 App 拉模式；旧测试替换；文档收尾 | 冷/热启动与线程池门禁 |
| **P4** | UI 显示增强（AGC/γ/倾斜/峰值）A/B | 可选后续项，未纳入本次交付 |
| **P5 ✅（App 路径）** | App 不再使用旧拉模式与旧 `libfft.so` ABI；`libfft.so` 仍构建给 CLI/测试 | 破坏性更新标注 |

### 8.1 交付状态与验证（2026-11-04）

**已落地**

| 层 | 实现 |
|---|---|
| 纯计算核心 | `kernel/dsp/spectrum.zig`（多分辨率 FFT / 对数带 / dB 软膝 / 频谱通量） |
| C ABI | `zk_dsp_spectrum_*`（`kernel/kernel.zig`、`include/kernel_bridge.h`） |
| 引擎服务 | `src/spectrum_service.c/h`（独立线程、50ms、懒启动、快速 stop） |
| 源适配 | 流式环形缓冲 / 内存 `mem_window` / 文件 `src/pcm_file_reader.c/h` |
| 事件 | 独立 `ev_fft` 最新帧槽；8-bit 量化 `{"type":"fft",...}` |
| 前端 | `EngineFft` → `PlaybackState.fft`；删除 `_pollSpectrum` / `PcmAnalyzer` 拉模式 |
| 启停 | `set_fft {enabled}` 启停引擎频谱线程（不再切 `pipeline_set_fft_enabled`） |
| 文档 | 本文件 + `architecture.md` / `audio-kernel-zig.md` / `audio-memory-playback.md` / `CHANGELOG.md` |

**验证结果**

- `zig build test`：770/770 通过（含 `spectrum.zig` 精度/节拍/左右分离测试）。
- CMake 构建 + `ctest`：40/40 通过（含新增 `test_pcm_file_reader`、
  `test_spectrum_service`）。
- `dart analyze lib`：0 issue。
- `flutter test`：1134 passed / 32 skipped。

**未纳入本次交付**

- P4 显示增强（AGC / γ / 高频倾斜 / 峰值保持线）保留为可选后续项，默认关闭。
- 进程级跨曲目 FFT 表缓存：当前按会话建表（<1ms），后续可优化。

## 9. 验收

### 9.1 功能/精度

- 正弦扫频：40 / 80 / 100 / 440 / 1k / 4k / 8k / 16k → 峰值落在期望带 ±1。
- 白噪声：所有带 > 0，无 NaN/Inf。
- 静音：全 0。
- 立体声分离：仅 L 有信号 → R 全 0。
- 5.1 中央声道：L=R；LFE 不影响输出。
- 0dBFS 正弦：峰值 ≈ 1.0；-72dB：≈ 0；-60dB：约 0.17。
- 交叉区 250–350Hz 扫频：无凹口/台阶。
- 节拍：120BPM 点击轨 → 命中数 ≈ 预期；持续正弦不误触发。

### 9.2 性能/启动

- 冷启动（频谱关）：与基线差异 < 1ms（多次取中位数）。
- 冷启动（频谱开）：首次 `set_fft` 建表 < 1ms，不阻塞音频回调/解码线程。
- 热启动/切歌：同会话 `reset` 只清状态；新会话建表 < 1ms。
- 线程池：解码吞吐与基线一致；无新增 worker；频谱线程空闲时 CPU≈0。
- 停止延迟：stop 每 10ms 检查一次，join 约 10ms 内返回。
- 内存：稳定，无每帧分配（用分配计数/Valgrind/ASan 验证）。
- 20Hz 持续 10 分钟：CPU < 2% 单核（x86_64），无丢帧累积。

### 9.3 UI

- 播放页 60fps；频谱开启不引入 UI isolate 的 FFI/磁盘读。
- 事件解析 + 重绘预算 < 1ms/帧。
- 丢帧/间隔变化（如后续 50↔300ms 降频）时插值不跳变。

## 10. 风险与回退

| 风险 | 缓解 |
|---|---|
| 解码快于实时，推送窗口取错位置 | 只取**播放位置**；流式环形缓冲 / 内存块索引 / 文件增量索引 |
| 文件模式磁盘慢 | 单帧 ≤64KB、失败跳过；必要时回退到最近样本环形缓冲 |
| 事件 JSON 开销 | 8-bit 量化后 ≈24KB/s 可接受；后续可加二进制事件 |
| Zig 移植影响启动 | 懒初始化 + 会话内表复用 + 独立线程；C 参考可随时回退 |
| 破坏性更新 | 旧调用方/旧 ABI 不兼容：CHANGELOG 显式标注，文档同步；不提供兼容层 |
| 观感变化（40–16k） | 文档标注 + 截图/录像对比；不做旧范围兼容 |

---

## 11. 决策记录

- **2026-11-04**：频率范围扩展为 40–16kHz；采用两级多分辨率 FFT（8192/2048），
  不上 CQT；引擎侧 50ms 推送，UI 改为纯事件接收端；频谱线程独立于解码线程池；
  **本次为破坏性更新**——App 播放路径不保留旧拉模式与旧 `libfft.so` ABI
  兼容；旧 `fft_*` 共享库仅保留给未迁移的 CLI/测试。
- **2026-11-04**：标准 FFmpeg 与 EraAudio **共用** MediaEngine 层频谱服务，
  只读 `on_pcm_out` 产物（mem blocks / `stream.pcm`），按播放位置取窗；
  SegStore 只是在线源的编码输入、不是频谱源；不引入 FFmpeg
  `showspectrum`/`av_fft`，`set_fft` 改为启停频谱服务。
