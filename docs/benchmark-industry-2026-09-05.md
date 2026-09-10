# EraAudio 自研解码内核 · 行业对比基准与评分

> 2026-09-05 · 实验性定位 · 配套 `app/core/audio-engine/tests/bench/scorecard.py`
> （一次跑完整矩阵 → CSV + 评分表 + 汇总 md）。
> 关联：[engine-integration-bench.md](engine-integration-bench.md)（EOF/错误语义、内存流式化、
> 样本数对齐、Opus「漂移」定档）、[format-support-matrix.md](format-support-matrix.md)（支持面）、
> [decode-optimization.md](decode-optimization.md)（2026-09-09：逐格式 ×RT 差距分析与提速专项，
> 本报告总表被 50× 实时封顶掩盖，看差距请以其逐格式口径为准）。

本文不评判任何库的「好/坏」绝对优劣，只做**同一语料、同机、可复现**的行业横评，
全部阈值与权重在文内写明，可原样重跑复核。文中数值 = 当前快照
`docs/benchmark-2026-09-10.md` / `docs/benchmark-2026-09-10.md`；
RSS/墙钟为采样值，贴近阈值（≤+3MB、R=50×）的行与总分跨轮有 ±0.5–4 分抖动，
多次运行实测 EraAudio 总分区间 **95.0–95.6**、Stable **97.6–98.1**、相对 FFmpeg
**97.0%–97.9%**（见 §7）——请以「区间 + 分差方向」判档。

---

## 0. TL;DR（结论先行）

- **EraAudio 总体 95.6/100（A+，区间 95.0–95.6）**，对引擎内 FFmpeg（Stable 路径）**归一 ≈97.9%**
  （Stable 97.6 A+，Δ≈−2.0；跨轮区间 97.0%–97.9%、Δ−2.0~−2.9）。分差几乎全部来自
  **内存维度个别格式的整缓冲/高工作集**（tta/dts）与 **flac 直解 CPU**；正确性维度有损类
  普遍 **corr≥0.999、±≤1 LSB**，无损类**逐位一致**。
- 与**独立专业工具**同口径对比：`flac -d` / `lame --decode` 100（各自格式，作地面真值参考），
  `speexdec` 80（极性分歧致其相对 libspeex 参考失配，见 §6）——自研与它们在「该格式」内
  同档或略低。独立参考缺失（opusdec/oggdec/wvunpack/dca/ac3 工具）的格式均**注明以 ffmpeg
  内嵌库为参考**。
- 已知短板（本报告诚实记录，按影响排序）：
  1. **直解 `.flac` native ×RT≈0.022（≈46× 实时，比 Stable ≈20× 慢）**——自研 flac 帧解码器
     CPU 待专项优化（与 engine-integration-bench §4/§5 结论一致）；同码流经 mka 轨 ≈0.0038×RT。
  2. **tta / dts 峰值 RSS 高**：tta 55MB、dts 85MB（EraAudio 平台值 ≈29MB）——疑似整缓冲/
     大块预留，未做多尺寸线性验证（待办）。
  3. **ac3 / eac3** 有损解码 PCM 与 ffmpeg 参考 corr≈0.96（rms16≈430 LSB 级）——高于 mp3/mp2/
     vorbis/aac/dts 的「±≤1 LSB」，属内容级实现差，需专项核对浮点舍入/耦合。
  4. **speex 输出极性分歧**：独立 `speexdec` 与 libspeex 族（含自研、ffmpeg）在此语料**反号**；
     自研与 libspeex 同号但 corr≈0.93（非 bit-exact），已按 |corr| 计分并如实注明，待专项核对。

---

## 1. 评分方案（行业口径，权重 + 阈值可复现）

总分 **100 = speed 40 + memory 30 + correctness 20 + coverage 10**。等级 A+≥95 / A≥90 /
B≥80 / C≥70 / D<70。

| 维度 | 满分 | 规则（写死、可复现） |
|---|---|---|
| **speed** | 40 | `score = 40·min(1, R/50)`，`R = 源时长/墙钟`（实时倍数）。**≥50× 实时即满分**，低于 50× 线性递减（25×→20、10×→8、1×→0.8）。 |
| **memory** | 30 | 相对**该引擎全部行的最小峰值 RSS**（实测平台值：EraAudio≈28.4MB、Stable≈33MB、ffmpeg CLI≈49.4MB、独立工具≈自身）：`overhead≤+3MB→30；≤+10→26；≤+25→20；≤+60→12；否则 4`。目的：只罚「相对自身平台地板明显抬高」的整缓冲/大工作集，不惩罚承载 FFmpeg 全家桶进程的绝对基数。 |
| **correctness** | 20 | **lossless**：native f32 PCM md5 == Stable == `ffmpeg -f f32le`（格式支持时另与 `flac -d`/ffmpeg s16 md5 交叉）→ 20（逐位）。**lossy**：`lenAbs ≤0.1%·refFrames 且 |corr|≥0.999 → 20`；`lenAbs≤1% 且 |corr|≥0.999 → 19`；`|corr|≥0.99→16`；`≥0.95→12`；`≥0.9→8`；否则 0。corr 取 1%–99% 中带、双声道平均、16bit LSB 域。**|corr| 计分**：纯反号不可闻（speex 极性分歧），避免误伤。 |
| **coverage** | 10 | era 行自研内核接管（`takeover=native`）且 rc=0 且全长解码 → 10；回退 FFmpeg → 0。 |

> memory 只测单尺寸（200s），无法区分「整文件整读」与「固定大缓冲」——这是本版已知口径
> 局限，报告中 RSS 异常行（tta/dts）显式标注「需多尺寸验证」。

---

## 2. 方法（测量口径）

**解码→PCM 直通，不重编码**（行业解码基准惯例）：

- 引擎两行用 `archoera-audio-engine <file> --engine-mode 0|1 --player-file out.wav --no-limiter`：
  skip encoder（**不编码 Opus**），float32 WAV、跟随源采样率/声道 → 本质「解码 →(恒等)重采样 → 落盘」，
  去掉 Opus 编码对解码耗时的主导污染（否则 Stable 各格式都 ≈0.005×RT、无法分辨格式差，见 engine-integration-bench §4）；
- CLI 行（ffmpeg / `flac -d` / `lame` / `speexdec`）解码到 s16 raw/wav；
- 指标：wall=`time.monotonic`；user+sys=`getrusage(RUSAGE_CHILDREN)` 差值；
  峰值 RSS=`/proc/<pid>/status VmRSS` 线程轮询 ≈2ms；短程（<0.6s）自动多次取样取最优 wall；
- ×RT（表中）= **墙钟/源时长**（越小越快）；实时倍数 R = 1/×RT。

**正确性参考（ground truth）**，每格式取一个「参考引擎」，lossy 全部对参考做长度 + corr/rms：

| 格式 | 参考 | 说明 |
|---|---|---|
| flac | `flac -d`（libFLAC 官方）+ ffmpeg | lossless 逐位双锚 |
| wav / wv / tta / mka(flac轨) | ffmpeg 内嵌（pcm_s16le / wavpack / tta / flac） | 无独立 CLI：**wvunpack / tta 工具缺失**，注明「以 ffmpeg 内嵌库为参考」 |
| mp3 | `lame --decode` | LAME 官方参考解码 |
| opus | `ffmpeg -c:a libopus` | **不**用 ffmpeg native（与 engine-integration-bench §6 一致） |
| vorbis | `ffmpeg -c:a libvorbis` | **不**用 native |
| aac(m4a/adts) | ffmpeg native aac | libaac 非解码器 |
| ac3 / eac3 / dts / mp2 | ffmpeg native（ac3/eac3/dca/mp2） | 无独立 CLI |
| speex | `ffmpeg -c:a libspeex` | 独立 speexdec 与 libspeex 族极性相反（见 §6），取 libspeex、按 \|corr\| |

---

## 3. 语料（200s 自造，`scorecard.py` 幂等生成，缺啥造啥）

统一 200s 立体声 16bit：**粉噪声×2 独立声道 + 440Hz 低通正弦**（高熵、接近真实音乐解码负载；
`base200.wav` 44.1k / `base16k.wav` 16k 供 speex）。派生（seed 固定可复现）：

| 文件 | 编码 | 大小 | 文件 | 编码 | 大小 |
|---|---|---|---|---|---|
| base200.wav | pcm_s16le | 35.3MB | ind.m4a | aac 192k | 4.8MB |
| ind.flac | flac | 26.9MB | ind.adts.aac | aac 192k(ADTS) | 4.9MB |
| ind.wv | wavpack -c2 | 26.8MB | ind.ac3 / ind.ec3 | ac3/eac3 256k | 6.4MB |
| ind.tta | tta | 26.7MB | ind.dts | dca 768k | 19.2MB |
| ind.mka | flac 轨封装 | 26.9MB | ind.spx | libspeex 16k c8 | 0.7MB |
| ind.mp3 / ind.mp2 | libmp3lame / mp2 192k | 4.8MB | base16k.wav | pcm_s16le | 12.8MB |
| ind.opus | libopus 128k | 2.9MB | ind.ogg | libvorbis q4 | 3.0MB |

覆盖 = 任务要求 15 轨全部 ≥1 中样本（含 mka/dts/speex/tta/adts），单轮全跑 ≈50s。

---

## 4. 机器 / 工具 / 构建（如实记录）

- **机器**：ASUS TUF-Gaming-F16，Linux 7.2.2-1-cachyos x86_64，**Intel Core i9-13980HX（32 线程）**，
  32GB RAM。单进程测量，无超频控制；数值为同机相对值，跨机直接可比的是**倍率**而非秒。
- **工具版本**：`ffmpeg n9.0.1`；`flac 1.5.0`；`lame 4.0`；`speexdec 1.2.1`；`zig 0.16.0`；
  `cmake 4.4.3`；`python 3.14.7`。
- **自研引擎**：`app/core/audio-engine/build/archoera-audio-engine`（2026-09-05 构建，
  链接 `zig-out/lib/libarchoera_kernel.a`，ReleaseFast kernel）。构建顺序
  `zig build -Doptimize=ReleaseFast && cmake --build build`。kernel 源码无晚于
  `libarchoera_kernel.a` 的修改。
- **自研侧全部行 takeover=native**（无回退），`zig build test` **596/596 通过**（未改 kernel，确认不受影响）。

---

## 5. 每格式 × 每引擎 得分表（完整数据见 `docs/benchmark-2026-09-10.md`
与 `docs/benchmark-2026-09-10.md`）

综合得分（speed40 + memory30 + correctness20 + coverage10；— = 该引擎不覆盖此格式）：

| 格式 | EraAudio(mode1) | Stable(FFmpeg) | ffmpeg CLI | 独立专业工具 | 独立专业工具 |
|---|---|---|---|---|---|
| flac | **97.9 A+** | 100 A+ | 100 A+ | `flac -d` 100 A+ | — |
| wav | 100 A+ | 100 A+ | 100 A+ | — | — |
| wv | 100 A+ | 100 A+ | 100 A+ | (无 wvunpack) | — |
| tta | **82 B** | 100 A+ | 90 A | (无 CLI) | — |
| mka(flac轨) | 100 A+ | 100 A+ | 100 A+ | — | — |
| mp3 | 100 A+ | 96 A+ | 100 A+ | `lame` 100 A+ | — |
| opus | 100 A+ | 100 A+ | 100 A+ | ffmpeg(libopus) 100 A+ | (无 opusdec) |
| vorbis | 100 A+ | 100 A+ | 100 A+ | ffmpeg(libvorbis) 100 A+ | (无 oggdec) |
| aac(m4a) | 100 A+ | 96 A+ | 100 A+ | (无独立) | — |
| aac(adts) | 100 A+ | 96 A+ | 96 A+ | (无独立) | — |
| ac3 | **92 A** | 100 A+ | 100 A+ | (无 CLI) | — |
| eac3 | **92 A** | 96 A+ | 100 A+ | (无 CLI) | — |
| dts | **82 B** | 96 A+ | 100 A+ | (无 CLI) | — |
| mp2 | 100 A+ | 96 A+ | 96 A+ | (无 CLI) | — |
| speex | **88 B** | 88 B | 88 B | ffmpeg(libspeex) 100 A+ | `speexdec` 80 B |

自研内核总体（15 格式平均）与 FFmpeg 归一：

| 引擎 | speed(40) | memory(30) | correctness(20) | coverage(10) | 总分 |
|---|---|---|---|---|---|
| **EraAudio(mode1)** | 39.9 | 27.6 | 18.1 | 10.0 | **95.6 A+** |
| Stable(mode0/FFmpeg) | 40.0 | 28.4 | 19.2 | 10.0 | 97.6 A+ |
| ffmpeg CLI（独立进程） | 40.0 | 28.8 | 19.2 | 10.0 | 98.0 A+ |

> **归一：95.6 / 97.6 = 97.9%（Δ−2.0）**；跨轮区间 97.0%–97.9%、Δ−2.0~−2.9。
> EraAudio 平均仅低于 FFmpeg 0.1(speed)、0.8(memory)、1.1(correctness)；memory 分差几乎全部
> 来自 tta/dts 两行。

---

## 6. 逐格式解读（速度 / 内存 / 正确性；差异与原因）

### 无损类（flac/wav/wv/tta/mka/pcm）—— 全部逐位
era 与 stable 的 float32 PCM **md5 逐字节一致**，且与 `flac -d`（s16）及 `ffmpeg -f f32le/s16le`
交叉一致 → **lossless bit-exact（flac 为 flac-d + ffmpeg 双锚）**。正确性全 20/20。

- **flac（直解）**：era ×RT≈0.020–0.022（≈46–50× 实时，贴近 50× 满分阈值），Stable 0.0011
  （≈900×）→ **差 ≈20×**，速度分 36.5–40（跨轮在满分边界）。与 engine-integration-bench §4/§5
  一致（native 直解 `.flac` 最慢、CPU 在自研 flac 帧解码器、待专项优化）。
  同内容封装为 **mka(flac 轨) 后 era ×RT 0.0036–0.0038**（≈260–280×），仅比 Stable 慢 ≈4.7× →
  直解路径才是瓶颈。此处如实记录现象，根因定位粒度仍停留在「自研 flac 帧解码器」，留待专项。
- **wav / wv / mp2 / mka**：era 与 Stable 同量级（0.0003–0.0038×RT，≈260–3000× 实时），满分。
  wv 直解略慢于 ffmpeg（0.0033 vs 0.0011）但在满分区间内。
- **tta**：era ×RT 0.0021（≈480×，满分）；但 **RSS 55MB vs 平台 28.4MB**（overhead ≈26.6MB）
  → memory 12/30、总分 82 B。27MB 输入却占 55MB，**疑似整缓冲/大块预留**；
  未做多尺寸线性验证（与 make_report.py「整缓冲随体积线性」判定口径需补测）。
- 独立参考缺失如实注明：**wv/tta 无独立 CLI（wvunpack/tta 未装）**，以 ffmpeg 内嵌库为参考。

### 有损类
- **mp3**：era corr 1.0、rms16 0.71、max16 1（≈±1 LSB，s16 域已近 bit-exact），长度与
  `lame --decode` 完全一致（8,820,000 帧）——gapless delay/padding 已由 engine-integration-bench
  §6 对齐。满分。Stable 行 96（memory 边界，见 §7 抖动说明）。
- **mp2**：corr 1.0、±≤1 LSB、长度对齐（8,820,864 帧）。满分。
- **opus**：era vs `libopus` corr 0.999335、rms16 62、max16 1731（个别样本差），长度对齐
  （9,600,000 帧，pre-skip 语义一致）→ 20/20。与 engine-integration-bench §6「Opus 长流漂移
  定档不存在、比对请用 libopus」一致。Stable 引擎内部走 ffmpeg native opus，与 libopus 全等
  （此语料 128k 以 CELT 为主）。
- **vorbis**：era corr 1.0、±≤1 LSB、长度对齐。满分。
- **aac(m4a/adts)**：era vs ffmpeg native aac corr 1.0、rms16 ≈0.01–0.02（近逐位）、长度一致
  （含 m4a elst/CodecDelay 语义；adts 8,821,760 帧含 ADTS 帧对齐填充）。两行满分；m4a 行 RSS
  采样接近 +3MB memory 边界，跨轮可能 96↔100。
- **ac3 / eac3**：era corr ≈0.96（ac3 0.964 / eac3 0.963）、rms16 ≈430、max16 ≈2700–3300 LSB、
  长度一致（含尾帧对齐 8,821,248 帧）→ correctness 12/20；行总分 ≈88–92 A（ac3 同时命中
  RSS +3MB memory 边界，ac3/eac3 各轮在 88↔92 间浮动）。这是有损类中唯一「corr 明显 <0.999」的：
  长度/容器语义已对齐，差异为 PCM 内容级（浮点舍入/耦合细节，rms≈430 LSB ≈ −37dBFS 级），
  可闻性需另验。待专项核对。
- **dts**：era corr 1.0、rms16 0.71、max16 1（±1 LSB，s16 域近逐位，与 format-support-matrix
  「dts 定点 bit-exact」自洽）；但 **RSS 84.8MB**（overhead ≈56MB）→ memory 12/30、总分 82 B。
  高工作集与 dca core 解码缓冲有关，未做多尺寸验证。
- **speex**：era 与 libspeex（ffmpeg）同号但 corr 0.932、rms16 478 级（非 bit-exact），长度一致；
  **独立 `speexdec` 输出与此语料反号**（sine 验证：src↔speexdec 同号 +0.70、src↔libspeex/era
  反号 −0.35/−0.70）→ 判断 libspeex 族极性源于 **ffmpeg 编码侧**，非 era 解码错误；故按
  |corr| 计分并取 libspeex 为参考。era correctness 8/20、总分 88 B。自研 speex 与 libspeex 的
  corr 0.93 仍是真实差距，需专项（含是否应对齐 speexdec 极性/精度的结论）。

### 内存维度总体
EraAudio 平台值 ≈28.4MB（speex/wav 行最低），15 行中 **13 行 ≤32MB（流式/固定小缓冲）**；
tta/dts 两行抬高到 55/85MB。相比 engine-integration-bench §3/§4 结论（mka 流式 ~35MB、m4a 高水位
已从 60→35MB 收口），本矩阵 EraAudio 多数行与那时同档或更低（28–32MB），与 AAC L2/allocator
裁剪方向一致；tta/dts 是唯二反例，列为优化项。

---

## 7. 已知限制 / 未覆盖项（诚实）

- 语料为**自造高熵立体声噪声**，非真实音乐；ac3/speex 内容级差异与真实曲目表现可能不同。
  真实语料回归可用仓库 `reference/` 或 `/tmp/eng` 既有 big*/nz*（时长/大小参差，仅作趋势）。
- **单轮抖动（实测区间）**：RSS/wall 为采样值，贴近阈值（≤+3MB、R=50×）的行跨轮可翻 1 格
  （±4 分）。本次共跑 4 轮实测：EraAudio 总分 **95.0–95.6**、Stable **97.6–98.1**、
  相对 FFmpeg **97.0%–97.9%**、Δ−2.0~−2.9；受影响的典型行为 flac 97.4↔97.9↔96.5（R≈50×
  边界）、ac3 88↔92、aac(m4a) 96↔100、Stable mp3/dts 96↔100（RSS +3MB 边界）。请以
  CSV/md 同轮快照判档，并优先看「era vs ffmpeg 分差与方向」而非个别行绝对分。
- 未覆盖内核已接管的小语种：ape/shn/tak/als/dst/mpc/wma/dsf/dff/latm 等（见 format-support-matrix.md）；
  本轮聚焦播放器主流 15 轨。
- 独立 CLI 缺失：**opusdec / oggdec / wvunpack / tta / dca / ac3 专用工具**未安装 → 对应格式
  以 ffmpeg 内嵌库为参考并如实注明（scorecard md §4）。
- RSS 只测单尺寸（200s）→ tta/dts「整缓冲 vs 固定大缓冲」未能判别，需 multi-size（建议复用
  make_report.py 的 spread 判定思路）。
- speed 用 wall（含 PCM 落盘 IO，双方一致）；user CPU 同 CSV 可查，结论同向。
- 温度/睿频未锁定：跨机请比**倍率与分差**，不比秒。

---

## 8. 复现（重跑命令）

```bash
cd /home/betastudio2/文档/SPlayer-Next/ArchoeraMusic/app/core/audio-engine
zig build -Doptimize=ReleaseFast && cmake --build build          # 先更新 ReleaseFast kernel
python3 tests/bench/scorecard.py --corpus /tmp/eng \
    --csv tests/bench/data/SCORE_$(date +%F).csv \
    --md  tests/bench/SCORE_$(date +%F).md \
    --build-tag <tag>                                            # 缺语料会自动 gen（--no-gen 可关）
```

- 语料缺失时 `scorecard.py` 用 ffmpeg 幂等生成 `ind.* / base200.wav / base16k.wav`（seed 固定）。
- 产物：`tests/bench/data/SCORE_*.csv`（原始+评分全字段）与 `tests/bench/SCORE_*.md`（自动汇总）。
- 配套既有基准驱动器：`tests/bench/run_bench.py`（Stable vs Era 全矩阵 OGG 管线，旧口径）、
  `tests/bench/gen_samples.sh`、`tests/bench/make_report.py`。
- `zig build test` 596/596 不受本文档/脚本改动影响（未触碰 kernel/src/build.zig）。


## 2026-09-06 更新（FLAC 提速后）

- FLAC io 前瞻缓存修复后重跑 scorecard（`docs/benchmark-2026-09-10.md` / docs/benchmark-2026-09-10.md，语料标准集）：
  flac 由 97.9(A+，speed 欠分) → **100.0(A+)**；EraAudio 平均总分 **95.6 → 95.7**（相对 Stable/FFmpeg 97.6 = **98.1%**，Δ-1.9）。
- 短板的“flac 直解慢”已消除（见 docs/engine-integration-bench.md §10）；本报告主表为 2026-09-05 快照，重跑命令见 §4/scorecard.py。


## 2026-09-10 更新（常驻内核池 score 口径扩测：并发/混杂/资源入分）

- 定位：面向「常驻内核池（Master+worker）生产形态」的**并发/混杂/首帧/资源**基准，与上表
  单流 ×RT 口径互补；报告产物见 `app/core/audio-engine/tests/bench/`：
  - `docs/benchmark-2026-09-10.md`（首刀：单流/并发伸缩/均布混杂/冷热首帧；headless 静音）
  - `docs/benchmark-2026-09-10.md`（scorecard 口径：**FFmpeg=100**，
    score=100·speed^0.6·(0.5cpu+0.5mem)^0.4；每项 5 轮去一最高一最低取平均）
- 工具（可复现）：`run_era_pool_bench.py` / `run_era_pool_score.py` / `_reswrap.py` /
  `bench_era_pool.c`（C，headless 经 zk_engine seam）；并发上限 **24**（本机内存受限）。
- 要点结果：单格式平均 132.1（opus/ac3≈105–108，wav≈218 最优）；并发 N=24 总分 334.8
  （era wall ≈44ms vs ffmpeg 91ms，era CPU 0.13s vs 1.54s，RSS ~37 vs ~53.5MB）；
  混杂 N=24 = 321.5。
- 口径/诚实：**机器无真实录音** → score 语料采用可复现「音乐结构仿真」曲目（和声/旋律/颤音/
  低噪，6/9/12s，44.1k 立体声），非版权；跨机请比 ×RT/加速比/分差方向而非毫秒。
- 说明：ffmpeg 测量为 N 进程并发、含进程启动；era 为单进程常驻池。与上表（scorecard 200s
  噪声语料、单流 50×RT 封顶）是两套口径，不可直接互换。

### 2026-09-10 · 解码 A 档提速（perf 指令口径）

> 依据 `docs/benchmark-2026-09-10.md`（era 指令=Stable 2.1–3.4×、CPI 更低 ⇒ 指令多非访存），
> 按 `decode-optimization.md` §4.2 **只做 A 档（零新增缓冲、精度中性、逐位一致）**：
> ① flac 位流取数（`Reader.readByte` 快路径 + `readBits` 快路径/comptime 掩码表 + `readBit`
> 直取）→ **flac 指令 600M→462M（−23%）**；② flac Rice 前缀 `readUnary1` 缓存批量数零
> （小）；④ aac Huffman `Vlc` 规范表 O(1)/长度查表 → **m4a 指令 455M→419M（−8%）**；
> flac LPC 滑动窗口 zip（合成语料中性，代码更简）。均 `zig build test` 622 逐位全绿、
> ctest 13/13。B 档（mp3 synth/imdct、aac MDCT 浮点重排）列为独立专项（需授权+corr 门禁）。
