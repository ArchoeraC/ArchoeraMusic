# 解码基准（2026-09-21）· 最小/最大 FFmpeg 基线 + 专业程序横评

> 日期：2026-09-21 · 机器：x86_64 EndeavourOS，i9-13980HX（32 逻辑核）· 构建：ReleaseFast 内核 + CMake 引擎。
> 口径：`tests/bench/scorecard.py`（15 格式 × 每引擎；墙钟 `time.monotonic`、峰值 RSS `/proc/<pid>/VmRSS` 2ms 轮询、静音 headless）。
> 本文**取代** `archive/benchmark-2026-09-10.md` §1 的解码 scorecard（该文其余章节仍有效）；`archive/benchmark-industry-2026-09-05.md` 为更早快照。
> 跨机请比**相对值 / ×RT / 归一百分比**，勿比毫秒。

---

## 0. TL;DR

- **基线分两档，均以 FFmpeg = 100 归一**：① **出厂最小音频 FFmpeg**（仓库 `build-ffmpeg-minimal.sh` 产物，纯 LGPL、仅音频、x86asm）；② **最大优化 FFmpeg**（额外 `--enable-lto -O3 -march=native -mtune=native`）——后者作为更强的对手基线。
- **EraAudio 100.0 vs FFmpeg 99.2 → 100.8%（>100）**，15/15 格式满分；与 `flac -d / lame / libopus / libvorbis / libspeex` 等**专业专用解码器持平**。
- 本轮落地三项真实修复（见 §3）：TTA/DTS 峰值 RSS 收口、AC-3/E-AC-3 抖动对齐 FFmpeg、Speex WB/UWB 对齐 libspeex。
- **诚实边界**：>100 成立的前提是本评分表 speed 维度**封顶 50× 实时**（本机所有格式远超阈值）；若按**不封顶的相对墙钟**严格计分，EraAudio ≈ **90.4%（区间 85.9–97.2%，8 轮）**、低于 100——这才是真实速度位置（见 §2.5/§5）。
- **冷/热启动首帧（§2.6）**：三格式**均快于 FFmpeg**（合计 flac 498 vs 743、mp3 154 vs 182、m4a 354 vs 962 µs）；m4a `open` 由 4.5ms 优化到 ~0.2ms —— `§3 启动门禁` 达成。

---

## 1. 基线口径

### 1.1 三档参照
| 档 | 来源 | 说明 |
|---|---|---|
| **稳定基线（出厂）** | `build-ffmpeg-minimal.sh` → `~/.local/ffmpeg-minimal` | 应用实际内嵌的 FFmpeg：`--disable-everything` 仅音频解码器 + 所需 demux/parser + OGG 封装；纯 LGPL；`nasm` 存在即启用 `x86asm` |
| **强基线（最大优化）** | 同上 + `--enable-lto --extra-cflags="-O3 -march=native -mtune=native"` → `~/.local/ffmpeg-max` | 比出厂基线更快，用于确认「我们不是靠对手弱」 |
| **专业程序** | 系统 `flac -d` / `lame --decode` / `speexdec`，以及 FFmpeg 内嵌 `libopus / libvorbis / libspeex` 路由 | 各格式的专用参考解码器 |

前置：**必须安装 `nasm`**（否则脚本退化 `--disable-x86asm`，FFmpeg 变慢，属不公平比对）。

### 1.2 评分（`scorecard.py`，总分 100 = speed40 + memory30 + correctness20 + coverage10）
- **speed(40)**：`40·min(1, R/50)`，`R = 源时长 / 墙钟`（≥50× 实时即满分）。
- **memory(30)**：相对**该引擎自身全部行的最小峰值 RSS（平台地板）**的增量：≤+3/10/25/60 MB → 30/26/20/12。
- **correctness(20)**：无损逐位=满分；有损 `lenAbs≤0.1%且|corr|≥0.999`=满分。
- **coverage(10)**：EraAudio 行「自研内核接管（native）且 rc=0 且全长」→10。
- 归一：`EraAudio 平均总分 / Stable 平均总分 × 100%`。

### 1.3 多轮与降噪
- 默认**连跑多轮**取每引擎平均总分（本轮：稳定基线 5 轮、最大优化基线 3 轮）；`scorecard.py --reps 2` 内部再对每项取均值。
- 可选 `--pin 8-11`（本机唯一 5600MHz 核）进一步压墙钟抖动。
- 机器 `governor=powersave`：墙钟有噪声；但 RSS/corr 几乎无噪声（见 §2.3），且 speed 饱和，故**总分零波动**。

---

## 2. 结果

### 2.1 每格式 × 每引擎（最大优化基线，3 轮一致）
| 格式 | **EraAudio** | Stable(FFmpeg) | ffmpeg CLI | flac -d | lame | libopus | libvorbis | libspeex | speexdec |
|---|---|---|---|---|---|---|---|---|---|
| flac / wav / wv / mka | **100** | 100 | 100/100/100/96 | 100 | — | — | — | — | — |
| tta | **100** | 100 | 90 | — | — | — | — | — | — |
| mp3 | **100** | 100 | 96 | — | 100 | — | — | — | — |
| opus | **100** | 100 | 100 | — | — | 100 | — | — | — |
| vorbis | **100** | 100 | 100 | — | — | — | 100 | — | — |
| aac(m4a) / aac(adts) | **100** | 100 | 100/96 | — | — | — | — | — | — |
| ac3 / eac3 / dts / mp2 | **100** | 100 | 96–100 | — | — | — | — | — | — |
| speex | **100** | 88 | 88 | — | — | — | — | 100 | 80 |

**结论**：EraAudio 在 **15/15 格式拿满分**，与各格式的专业专用解码器持平，并全面 ≥ 通用 `ffmpeg` CLI。

### 2.2 总体（对 FFmpeg 归一）
| 引擎 | speed(40) | memory(30) | correctness(20) | coverage(10) | 平均总分 |
|---|---|---|---|---|---|
| **EraAudio** | 40.0 | 30.0 | 20.0 | 10.0 | **100.0 (A+)** |
| Stable/FFmpeg | 40.0 | 30.0 | 19.2 | 10.0 | 99.2 (A+) |
| ffmpeg CLI | 40.0 | 28.0 | 19.2 | 10.0 | 97.2 (A+) |
| flac -d / lame / libopus / libvorbis / libspeex | 40.0 | 30.0 | 20.0 | 10.0 | 100.0 (A+) |
| speexdec | 40.0 | 30.0 | 0.0 | 10.0 | 80.0 (B) |

> 注：专业程序行只覆盖其对应格式（例如 `flac -d` 仅 flac 行），是「各格式最强者」参照，非全格式均值。
> Stable 为 99.2 而非 100 的唯一原因是 **speex 行 corr 0.9317**（FFmpeg native speex 与 libspeex 的差异）。

**EraAudio / FFmpeg = 100.8%（Δ +0.8）**。出厂最小基线与最大优化基线**结果相同**（见 §5 原因）。

### 2.3 多轮稳定性（总分 σ=0）
| 轮次配置 | 轮数 | EraAudio | Stable/FFmpeg | 比值 |
|---|---|---|---|---|
| 出厂最小基线（默认） | 5 | 100.000 (σ=0) | 99.200 (σ=0) | **100.806%** ×5 |
| 出厂最小基线（`--pin 8-11`） | 3 | 100.000 | 99.200 | **100.806%** ×3 |
| 最大优化基线 | 3 | 100.000 | 99.200 | **100.806%** ×3 |

逐格式原始量轮间波动（5 轮均值±σ）：RSS σ ≤ 0.2 MB（tta 9.53±0.12、dts 9.93±0.17、speex 9.06±0.20），corr 恒 1.0（opus 0.9993）；仅墙钟有噪声（受 governor 影响），但因 speed 封顶不进入分数。

### 2.4 本轮修复的关键原始测量（最大优化基线，era 行）
| 格式 | 修复前 | 修复后 | 主要变化 |
|---|---|---|---|
| tta | 82（RSS 35.4MB，memory 12） | **100**（RSS 9.0–9.8MB，memory 30） | 去掉整文件 alloc |
| dts | 82（RSS 65.2MB，memory 12） | **100**（RSS 9.7–10.1MB） | core 流式逐帧 |
| ac3 | 92（corr 0.964） | **100**（corr 1.000） | 补 AVLFG 抖动 |
| eac3 | 92（corr 0.963） | **100**（corr 1.000） | 同上 |
| speex | 88（corr 0.932） | **100**（corr 1.000） | 对齐 libspeex |

（flac/wav/wv/mka/mp3/opus/vorbis/aac/mp2 本轮前即为 100。）

### 2.5 补充：速度不封顶（严格口径）

§2.2 的「100.8%」建立在 **speed 维度 50× 实时封顶**之上（本机所有格式远超阈值 → speed 恒 40）。
为给出**不受封顶掩盖**的诚实数字，这里把 speed 一项改为**不封顶的相对墙钟**：

```
speed_strict(fmt) = 40 · (FFmpeg_wall / era_wall)     # >1 = era 更快；FFmpeg 自身 = 40
其余 memory30 / correctness20 / coverage10 不变
```

同批数据（8 轮：出厂最小基线 5 + 最大优化基线 3）实测：

| | EraAudio 严格均分 | FFmpeg | 相对 |
|---|---|---|---|
| 8 轮合并 | 90.4 | 99.2 | **90.4%（区间 85.9–97.2%）** |

逐格式相对速度 `FFmpeg_wall/era_wall`（最大优化基线，>1 = era 更快）：

| era 更慢（<1） | 比值 | era 更快（≥1） | 比值 |
|---|---|---|---|
| dts | 0.23 | speex | 1.32 |
| ac3 | 0.35 | mp2 | 1.18 |
| mka(flac轨) | 0.35 | aac(adts) | 1.17 |
| flac | 0.43 | | |
| eac3 | 0.56 | | |
| aac(m4a) | 0.58 | | |
| vorbis | 0.63 | | |
| opus | 0.65 | | |
| tta | 0.70 | | |
| wv | 0.78 | | |
| mp3 / wav | 0.79 / 0.85 | | |

**解读**：
- 一旦解除封顶，EraAudio 相对 FFmpeg 落到 **≈90%（<100）**——这才是**真实解码速度**的诚实位置；差距集中在
  flac/mka/dts/ac3（1.2–4.4×），个别格式（speex/adts/mp2）可反超。
- 区间较宽（85.9–97.2%）源于**墙钟噪声**（`governor=powersave`、P/E 混合、未绑定核时的迁移/热抖动）——
  恰是被封顶评分掩盖的那部分；RSS/corr 两项几乎无噪声。
- 因此对外表述应区分：**「综合评分（含封顶 speed）100.8%」** 与 **「严格速度口径 ≈90%」**；
  后者指向 `decode-optimization.md` 的 A 档提速专项（需授权、且不改音质）。

### 2.6 冷/热启动 → 首帧（vs FFmpeg）

工具 `tests/bench/bench_coldstart.c`（headless，流式模式 = 一次 `pipeline_process` ≈ 一块音频；era/stable **交错**各 40 次取 p50，消顺序/热漂移）。分两段：`create`=`pipeline_create`（开解码器+建 DSP/缓冲），`first`=首次产出 PCM。

**热启动（p50, µs；m4a 为提速后）**：

| 文件 | era create | era first | Stable create | Stable first | 合计 era | 合计 Stable |
|---|---|---|---|---|---|---|
| flac | 59 | 439 | 412 | 331 | **498** | 743 |
| mp3 | 35 | 119 | 145 | 37 | **154** | 182 |
| m4a | 168 | 186 | 935 | 27 | **354** | 962 |

**冷启动（每会话真实付出：`pool begin(init)` + create + 首帧，p50 µs）**：

| 文件 | era begin+create | era first | pool init 单项 |
|---|---|---|---|
| flac | 757 | 596 | ≈20–35 |
| mp3 | 518 | 362 | ≈20–35 |
| m4a | 775 | 376 | ≈20–35 |

**结论（提速后）**：
- **三格式首帧均快于 FFmpeg**（合计 498 vs 743、154 vs 182、354 vs 962），`engine-master-pool-design.md` §3 启动门禁**达成**。
- m4a 由「落后 ≈4.8×」转为「领先 ≈2.7×」：根因是 `parseStsz` **逐样本 `readAt`**（≈8600 次 seek+read 系统调用）→ 改为**整块读入再解析**后，`open` 从 **4.5ms → ~0.2ms**（冷启动 `begin+create` 11446 → 775µs）。

复现：`./build/tests/bench_coldstart /tmp/eng/ind.flac 40 2>/dev/null`（`ind.mp3`/`ind.m4a` 同理）。

---

## 3. 本轮修复（代码）

1. **TTA/DTS 峰值 RSS 收口**（`kernel/fmt/tta/lib.zig`、`kernel/fmt/dts/lib.zig`）
   - TTA：只读 22B 头 + 尾部 seek 表（分块构建偏移索引），音频帧按偏移 `seek` 读入**定长复用缓冲**；常驻内存与文件体积无关。**PCM 逐位不变**（改前/改后 f32 md5 相同）。
   - DTS：DCA core 按 sync 滑窗**逐帧流式**解码（定长帧缓冲），不再整读；裸 core 采用「扫描建索引 + 播放」两遍，**seek** 前向顺序丢弃、后向从头重建，保证输出与整段一致（corr 1.0）。
2. **AC-3 / E-AC-3 抖动对齐 FFmpeg**（`kernel/fmt/ac3/{ctx,mantissa,lib}.zig`）
   - 修正 `av_lfg_get` 公式（现行 `state[i-24]+state[i-55]`，原为旧式三加项）+ **初始化 AVLFG**（原全 0 导致常数抖动）+ LFE 指数位宽；抖动状态移入 `Ctx.dith`（每实例一份，seek 复位）。逐 bin 对照自建 FFmpeg n9.0.1 成功。corr 0.964/0.963 → **1.0**。
3. **Speex WB/UWB 对齐 libspeex**（`kernel/fmt/spx/*`）
   - 低带 NB 解码器在 WB/UWB 下改用 **wideband 高通**（libspeex `SPEEX_SET_WIDEBAND=1` 语义；FFmpeg native 用 narrowband）+ 若干浮点语义对齐。corr 0.932 → **1.0**；WB/UWB/VBR/立体声 golden 参考改为 `ffmpeg -c:a libspeex`（已核验与 libspeex 输出 md5 全等）。
4. **m4a 启动提速**（`kernel/fmt/m4a.zig`）：`stsz/stco/stts/stsc` 表解析原**逐条目 `readAt`**（每次 seek+read 一次系统调用，万级样本 → 万级 syscall）改为**整块读入再解析**；m4a `open` **4.5ms → ~0.2ms**，冷启动首帧随之达标（详见 §2.6）。
5. 前置（同批，另行记录于 `audio-kernel-zig.md`）：EraAudio 在线流回调（`zk_decoder_open_cb`）、opus 解码非确定性修复、EraSync 常驻池覆盖内存/回调源、`zk_submit` 结构化 FFI。

---

## 4. 复现

```bash
# 前置：nasm（否则 FFmpeg 退化无 SIMD）
#   本机无包权限时：源码编译到 ~/.local（见 runbook）

# ① 出厂最小 FFmpeg（纯音频 LGPL，x86asm）
PATH="$HOME/.local/bin:$PATH" bash app/core/build-ffmpeg-minimal.sh

# ② （可选）最大优化基线
#    复制脚本，改 PREFIX 并加 --enable-lto --extra-cflags="-O3 -march=native -mtune=native"
FFMPEG_PREFIX="$HOME/.local/ffmpeg-max" bash /tmp/build-ffmpeg-max.sh

# ③ 引擎
cd app/core/audio-engine
zig build -Doptimize=ReleaseFast
PKG_CONFIG_PATH="$HOME/.local/ffmpeg-minimal/lib/pkgconfig" \
  cmake -S . -B build-min -DCMAKE_BUILD_TYPE=Release && cmake --build build-min -j
# 最大优化：同上把路径换 ffmpeg-max、构建目录换 build-max

# ④ 多轮评测（结果按目录输出，不污染仓库）
cd tests/bench
for i in 1 2 3 4 5; do
  python3 scorecard.py --engine ../../build-min/archoera-audio-engine \
    --reps 2 --no-gen --pin 8-11 \
    --csv /tmp/sc_$i.csv --md /tmp/sc_$i.md
done
```
> 构建坑：改 Zig 源码后必须先 `zig build -Doptimize=ReleaseFast` 再 `cmake --build`，否则链旧 `libarchoera_kernel.a`。

---

## 5. 诚实边界与未覆盖

- **speed 封顶**：评分 speed 维度在 50× 实时封顶；本机所有格式远超阈值（×RT ≈ 0.0005–0.008），故 speed 恒 40，FFmpeg 再优化（LTO/`-march=native`）也不改变总分与比值。**因此「100.8%」不得解读为「解码更快」**。
- **不封顶速度口径**：把 speed 项换成不封顶的相对墙钟后，EraAudio **≈ 90.4%（区间 85.9–97.2%，8 轮）** vs FFmpeg 99.2 → **<100**；EraAudio 多数格式仍慢于 FFmpeg（dts ≈4.4×、ac3 ≈2.9×、mka/flac ≈2.3–2.9×、eac3/aac/vorbis/opus/tta 1.4–1.8×；speex/adts/mp2 反超）。速度差距的根因与优化对象见 `decode-optimization.md`（指令数偏高，非访存）。
- **DTS 取舍**：裸 core 为两遍解码（扫描+播放，墙钟约 2×）、**后向 seek 为 O(n)**（重建解码器历史）；原实现靠全量 PCM 常驻换 O(1)。`.dtshd` 容器 / EXSS-XLL / LBR-XBR 分支**未流式化**（仅预解码后立即释放文件缓冲，PCM 仍整段常驻）。
- **AC-3 参考面**：era 内部经 s16 中间表示，对 ffmpeg 的 s16 参考有 **±1 LSB**（`rms16≈0.74`、`max16=1.0`），满足 `|corr|≥0.999` 与 ±1 LSB 纪律。
- **memory 计分为「各引擎相对自身地板」**：`ffmpeg CLI` 平台地板高（≈50MB），故其绝对值不参与惩罚；引擎行地板低（≈9MB），整缓冲型解码器会被如实罚分（TTA/DTS 修复前的 12 分即此）。
- **专业程序覆盖**：`opusdec / oggdec` 本机未装，opus/vorbis 以 FFmpeg 内嵌 `libopus/libvorbis` 路由为专业参照；`speexdec` 在本语料与 libspeex 族存在极性/实现差异，按 `|corr|` 计分且仅 80 分。
- **机器噪声**：`governor=powersave`；已用多轮 + `--pin` 收敛，总分 σ=0。

---

## 6. 文档变更

- 新建本文（2026-09-21）：最小/最大 FFmpeg 双基线 + 专业程序横评 + 多轮稳定性 + 三项修复；
  §2.5 另附**速度不封顶（严格口径）**结果（≈90.4%，区间 85.9–97.2%）；§2.6 附**冷/热启动首帧**
  基准（工具 `tests/bench/bench_coldstart.c`）。
- `archive/benchmark-2026-09-10.md` §1：解码 scorecard 由本文取代（该文其余结论仍有效）。
- `archive/benchmark-industry-2026-09-05.md`：更早快照，供历史对照。
- `decode-optimization.md`：TTA/DTS 内存、AC-3/E-AC-3 corr、Speex 对齐三项状态更新。
