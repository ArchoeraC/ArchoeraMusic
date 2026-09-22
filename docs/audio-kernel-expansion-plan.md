# 音频内核能力扩张规划（四方向）

> 状态：**规划稿 v1 · 2026-09-22**
> 定位：在 `docs/audio-kernel-zig.md`（内核权威设计 / 逐格式接管路线）既有的「解码接管」主线之外，
> 规划下一阶段要扩张的**四项内和能力**——**① 可听频段 DSP · ② 在线流/非本地源 · ③ 更多格式接管 ·
> ④ 性能/内存**。本文只定**目标、现状、候选清单与验收门**；具体排期与优先级在下一步再定。
>
> 关系：**本文不替代** `audio-kernel-zig.md`——架构、依赖账本、逐格式裁决、不变量仍以该文为准；
> 本文是它 §19 路线之外的「能力扩张」子计划。冲突处以 `audio-kernel-zig.md` 为准。

---

## 1. 四方向总览

| # | 方向 | 一句话目标 | 现状 | 主要依托 |
|---|---|---|---|---|
| ① | **可听频段 DSP** | 把 C DSP 下沉 Zig 内核，并在**非次声（可听）频段**提供更丰富的处理 | DSP 仍是 C（`src/equalizer.c` 等），`zk_dsp_*` 仅在 `kernel_bridge.h` 预留；内核无 `dsp/` | `audio-kernel-zig.md` §14；`libfft.so` ABI |
| ② | **在线流 / 非本地源** | 自研内核直接消费远端流，覆盖 Subsonic 之外的音源 | `zk_decoder_open_cb` + `Reader.callback` 已落地（2026-09-21）；应用侧接线、Range seek、断流恢复待做 | `audio-kernel-zig.md` §6.1 / §8.4；`audio-memory-source.md` |
| ③ | **更多格式接管** | 补齐剩余长尾格式、拉高生产引擎接管率、打通曲库白名单 | 常见格式 L1 已清零；余 SV7 / Shorten 等；L2/L3 有缺口 | `format-support-matrix.md`；`audio-kernel-zig.md` §3.3/§3.7 |
| ④ | **性能 / 内存** | 在「零新增缓冲」纪律下继续砍指令、收口常驻内存与启动 | A 档已吃尽、B 档暂停；TTA/DTS RSS 已收口 | `decode-optimization.md`；`engine-master-pool-design.md` |

> **「非 subsonic 区域」的界定（方向①）**：音频链常见的低频管理是先用**次声/高通滤波器**（subsonic，
> 约 <20 Hz 去隆隆声）打底，再在**其余可听频段**做处理。本方向即在「subsonic 打底之外的可听频段」
> 提供更多 DSP 能力（EQ / 动态 / 立体声 / 等响度等）。

---

## 2. 方向① 可听频段 DSP

### 2.1 现状

| 模块 | 现状实现 | 位置 |
|---|---|---|
| 均衡器 | C，**固定 10 段** ISO 频点（31.25…16k）+ preamp，±12 dB | `src/equalizer.c/.h`（`EQ_BANDS=10`） |
| 响度 | C，EBU R128，扫描 / 应用两种模式 | `src/loudness.c/.h` |
| 限幅 | C，阈值可设（默认 −1 dB） | `src/limiter.c/.h` |
| 频谱 | C，`libfft.so`，Dart 经 FFI 拉窗 | `src/fft.c/.h` |
| 变速变调 | Rust `tempo-rs`（signalsmith-stretch）过渡 | `src/tempo.c/.h` |
| 重采样 | FFmpeg `libswresample` | `src/resampler.c/.h` |
| 内核侧 | **未移植**：无 `kernel/dsp/`；`zk_dsp_*` 仅预留 | `include/kernel_bridge.h:15` |

App 侧只暴露「EQ 开关 / 10 段增益 / preamp」（`app/lib/stores/prefs_audio_fx.dart`），链路为
解码 → EQ → 变速 → 响度 → 限幅 → 输出。

### 2.2 目标

1. **地基：DSP 下沉 Zig**（对齐 §14）——`equalizer/loudness/limiter/fft/resampler/tempo` 逐函数移植进
   `kernel/dsp/`，经 `zk_dsp_*` 被 C 壳调用；`libfft.so` 的 Dart ABI **零改动**，`fft_bindings.dart` 不变。
2. **扩张：可听频段新功能**——在既有 EQ/响度/限幅之上，按需增加处理块（候选见 2.3）。

### 2.3 候选功能清单（下一批内核实现候选，待定优先级）

| # | 候选 | 说明 | 价值 | 备选参考 |
|---|---|---|---|---|
| D1 | **参数化 EQ** | 频点/Q/增益可配，支持峰值/低架/高架，替代固定 10 段 | 用户可调空间大、对齐主流播放器 | WebAudio BiquadFilter / SoX |
| D2 | **次声/低频管理** | 高通（subsonic）去隆隆 + bass shelf；**这是方向①的「打底」** | 保护扬声器、清理低频泥 | 通用一阶/二阶高通 |
| D3 | **动态/DRC** | 压缩器（阈值/比率/起停）+ makeup；扩展响度链 | 小音量听感、夜间模式 | EBU R128 动态门限 |
| D4 | **耳机 crossfeed** | 交叉馈送，改善耳机声场 | 耳机用户常用 | Bauer / BS2B |
| D5 | **立体声宽度 / M-S** | 中侧宽度调节、声道平衡 | 简单、听感明显 | 通用 M/S |
| D6 | **等响度（loudness contour）** | 随音量补偿低/高频 | 小音量补偿 | ISO 226 |
| D7 | **Gapless / crossfade** | 曲间无缝 / 淡入淡出（偏管线，常与 DSP 同议） | 专辑连贯性 | — |
| D8 | **频谱可视化增强** | 倍频程/更多 bin/峰值保持（`fft` 已有基础） | 播放页观感 | — |

### 2.4 约束与验收

- **不破坏 P5 护栏**：`libfft.so` ABI、`zk_dsp_*` 契约、`stream.wav/.pcm` 格式不变；
- **精度纪律**：无损链路逐位；有损按 `decode-optimization.md` §4.2 门禁（`|corr|≥0.999` 且 ±≤1 LSB）；
- **性能**：DSP 在解码侧 worker 完成，禁止回到 Dart 主 isolate 逐样本处理（对齐 AGENTS「重计算下沉」）；
- **验收**：每个 DSP 块单独单测 + `tests/test_equalizer.c` 等黄金断言复用 + 与 C 实现逐位/逐块对照，
  移植完成后删除对应 `src/*.c` 过渡实现。

---

## 3. 方向② 在线流 / 非本地源支持

### 3.1 现状（2026-09-21 进展）

- `Reader.callback` + `decoder.openReader` + `zk_decoder_open_cb` **已落地**；C 壳以 **FFmpeg AVIO** 作宿主
  传输，EraAudio 模式下的 **http(s) 源**直接进自研内核（此前一律回退 FFmpeg）；
- `Reader.callback` 两处缺陷（大请求丢预读、seek 后游标不同步）已修并有单测；
- EraSync 常驻池覆盖 path/mem/cb 三源（`zk_engine_open_mem/_cb`）；
- 详见 `audio-kernel-zig.md` §6.1 落地块。

### 3.2 待做

| # | 事项 | 说明 |
|---|---|---|
| N1 | **应用侧接线** | 把 Subsonic 之外的音源（Neko 等，见音源注册表）接入 cb/直连路径，而非一律「Dart 预下载→本地文件」 |
| N2 | **Range seek 完整化** | `on_seek` 发 Range 重定位；验证远端 seek 与本地逐样本一致（含 EOF 后 seek） |
| N3 | **断流 / 超时 / 重连** | `Reader.abort()` 中断、缓冲欠载、宿主重试的语义与错误上报 |
| N4 | **缓冲策略** | 每路 callback Reader 私有缓冲与目标内存预算（对齐 `audio-memory-source.md`） |
| N5 | **去 FFmpeg 传输依赖（可选）** | 传输层由宿主注入是 P2 允许的；评估是否用纯宿主实现替代 FFmpeg AVIO，彻底摆脱 FFmpeg 传输栈 |
| N6 | **格式覆盖** | 确认 cb 路径下各接管格式（flac/wav/mp3/opus…）seek/时长语义一致 |

### 3.3 红线

- **P2 零网络栈不变**：socket/TLS/Range/重定向**一律宿主注入**，内核只经 `callback` 消费字节流；
- 不支持网络栈时退回「预下载本地」（现状默认路径），任何组合不丢播放能力。

---

## 4. 方向③ 更多格式接管

### 4.1 现状（见 `format-support-matrix.md`）

- **L1 内核自研解码**：常见格式已全覆盖；MP4 容器 codec 面扩展、DST/TAK/ALS 已接入；
  残余仅小众圈（Musepack **SV7**、Shorten、DTS-LBR 多声道真实样本、wmavoice 浮点对拍等）；
- **L2 生产引擎接管率**：以 FFmpeg 兜底为主，Zig 已接管格式优先；接管门控（§8.4.2 #2）待验收；
- **L3 曲库白名单**：`.mp2/.mp1/.wavpack 家族/.tta/.tta...` 等部分 TagLib 不支持或未入白名单，
  存在「能播不能收藏」的隐性缺口；「内核 Info 兜底」为**产品决策项**（未实施）。

### 4.2 候选

| # | 候选 | 归属 | 说明 |
|---|---|---|---|
| F1 | **Musepack SV7** | L1 | SV8 已完成；SV7 参考 `mpc7.c` |
| F2 | **Shorten（.shn）** | L1 | 老无损，参考 `shorten.c` |
| F3 | **MP2 / MP1 落库** | L3 | 内核已可解，补 scanner 白名单即可（非内核工作） |
| F4 | **内核 Info 兜底** | L3/产品 | tta/spx/shn/dts/ac3/… 无 TagLib 元数据者，经内核 probe→Info 取时长/位深入库 |
| F5 | **接管门控 + 接管率监控** | L2 | 静态位图 + `backend` 字段监控（`audio-kernel-zig.md` §8.4.2） |
| F6 | **残余长尾** | L1 | DTS-LBR 多声道、wmavoice 浮点对拍等，按 §3/P2 处理 |

### 4.3 纪律

- 新增格式一律走 `audio-kernel-zig.md` §3.3「自研 vs 引入」裁决与 §3.7 裁决表；
- **命名自有化**：内核符号 `era_` 前缀，禁止照搬 FFmpeg/libspeex 等上游标识符；
- **验收**：无损 bit-exact / 有损 corr golden；每格式独立许可审查并登记 `THIRD-PARTY-LICENSES.md`。

---

## 5. 方向④ 性能 / 内存

### 5.1 现状（见 `decode-optimization.md`）

- **A 档（精度中性）已基本吃尽**：flac 位流 −23%、aac Huffman −8% 等，零新增缓冲、逐位一致；
- **B 档（浮点重排/SIMD/快速变换）暂停**：仅在明确授权 + 有损 corr 门禁下启动，无损类绝不允许；
- **内存侧已收口**：TTA 35→9 MB、DTS 65→10 MB（2026-09-21）；
- **启动**：m4a `open` 4.5 ms→~0.2 ms（stsz 整块读），冷启动三格式快于 FFmpeg。

### 5.2 待做

| # | 事项 | 说明 |
|---|---|---|
| P1 | **公共 PCM/convert 地板** | 连 wav 都比 FFmpeg 慢 ~1.8×；一改全格式受益 |
| P2 | **B 档提速（需授权）** | mp3 `synthGranule`/`imdct36`、aac MDCT 等；每步过 corr 门禁与启动硬约束 |
| P3 | **实例内存池 / Reader 复用** | `audio-kernel-zig.md` §8.4.2 #4，128 并发下消 malloc/free 风暴 |
| P4 | **冷/热首帧与常驻 RSS 持续看护** | 每次改动复测，回退即回滚（`decode-optimization.md` §4.2 硬约束） |
| P5 | **并发/批量基准** | 128 路混合格式的 fd/内存/CPU 受控（`engine-master-pool-design.md`） |

### 5.3 纪律

- **零新增缓冲**（不加大块预读/位流宽缓冲/持久中间缓冲）；预计算限定「全局 comptime 表 / 每实例
  O(小) prepare / 派发 hint」三层；
- 主指标为 `perf stat` **指令数下降**，且**冷/热首帧与常驻开销不劣于 FFmpeg 基线**；
- 无损逐位、有损 `|corr|≥0.999` 且 ±≤1 LSB。

---

## 6. 优先级与执行顺序（草稿，下一步再定）

建议默认顺序（可在下一步调整）：

1. **方向② 应用侧接线 + Range seek 完整化**（打通非 Subsonic 在线源，收益直接可见）；
2. **方向① 地基（DSP 下沉 Zig）** → 再叠加 D2 次声/低频管理、D1 参数化 EQ；
3. **方向④ P1 公共地板 + P3 内存池**（与方向①/②并行、互不阻塞）；
4. **方向③ F3/F4 白名单快赢 + F1/F2 长尾**（独立子项，可随时插入）。

> 待定项：D3–D8 功能取舍、B 档是否授权、F4 是否把影视音轨当曲目。

---

## 7. 不变量与红线（汇总）

- `archoera_mediaengine.h` 导出符号 / JSON 协议 / `libfft.so` ABI / `stream.wav/.pcm` 格式**不变**（P5）；
- 内核**零网络栈**，传输宿主注入（P2）；视频解码不做（P4）；
- 无损逐位、有损 corr 门禁；零新增缓冲；B 档需授权；
- 内核符号 `era_` 前缀，不照搬上游标识符；
- 系统调用走 `app/native/platform` 桥接，Dart 不直连平台。

---

## 8. 关联文档

- [audio-kernel-zig.md](audio-kernel-zig.md) —— 内核权威设计与逐格式接管路线（§14 DSP、§6.1 在线流、§19 路线）
- [decode-optimization.md](decode-optimization.md) —— 解码提速专项（方向④）
- [format-support-matrix.md](format-support-matrix.md) —— 格式支持三维矩阵（方向③）
- [audio-memory-playback.md](audio-memory-playback.md) / [audio-memory-source.md](audio-memory-source.md) —— 内存播放与源（方向②④）
- [engine-master-pool-design.md](engine-master-pool-design.md) —— 主控/线程池架构（方向④）
- [benchmark-2026-09-21.md](benchmark-2026-09-21.md) —— 最新基准
