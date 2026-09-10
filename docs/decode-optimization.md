# 解码提速专项：逐格式 CPU 差距与优化对象

> 状态：**工作稿（2026-09-09）· 未动代码**。数据源：
> `app/core/audio-engine/tests/bench/SCORE_2026-09-06.md`（scorecard 快照，
> 同机同语料）与 `benchmark-industry-2026-09-05.md` / `engine-integration-bench.md`。
> 本文件回答一件事：**总表看 era ≈ FFmpeg 98%，为何还要谈解码效率？差距在逐格式 ×RT，
> 被 50× 实时封顶遮住了。**
> 关联：[benchmark-industry-2026-09-05.md](benchmark-industry-2026-09-05.md)（评分口径）、
> [audio-kernel-zig.md](audio-kernel-zig.md) §8.4.2（Phase G 优先子项，含基准先行）、
> [engine-master-pool-design.md](engine-master-pool-design.md)（调度/并发侧，本专项与之正交）。

---

## 0. TL;DR

- **总分层面 era 已被封顶掩盖**：speed 维度所有行都 ≥50× 实时 → 全 40/40，总分差
  （−1.9）实际来自 memory（tta/dts RSS）与 correctness（ac3/eac3/speex），不是速度。
- **但逐格式 ×RT，era 普遍落后引擎内 FFmpeg（Stable）1.3–3.6×**；扣掉公共地板
  （wav 行）后，codec 纯解码增量差距更明显（aac 约 3–5×、flac/mka 约 3–4×）。
- 真机代价：移动端/ARM 电池与 CPU、128 路并发余量、播放时多任务头room——scorecard
  看不到，因为本机 i9 全格式都远超实时。
- **结论**：值得开「解码提速专项」，但**先用 `perf` 定位热循环，再对对象下刀**，
  不拍脑袋。第一批候选（按收益排序）见 §4。

---

## 1. 前提核对：为什么"总表 98%"与"效率偏低"不矛盾

SCORE 计分 `speed = 40·min(1, R/50)`：**达到 50× 实时即满分**，之上不区分。
本机（i9-13980HX，ReleaseFast）era 最慢行 flac/mka ×RT≈0.003–0.004（≈250–330× 实时），
早已越过 50× 门槛 → 速度维度无法再分辨差距。因此**「相对 FFmpeg 98%」反映的是
"都够快"，不反映"一样快"**。逐格式 wall/×RT 才是看 decode 效率的正确口径。

## 2. 逐格式差距（SCORE_2026-09-06，era vs 引擎内 Stable）

| 格式 | era ×RT | Stable ×RT | ratio | decode 增量估* |
|---|---|---|---|---|
| flac | 0.00307 | 0.00107 | 2.9× | ~3.3× |
| mka(flac轨) | 0.00383 | 0.00107 | 3.6× | ~4.3× |
| aac(adts) | 0.00180 | 0.00056 | 3.2× | ~5× |
| aac(m4a) | 0.00157 | 0.00082 | 1.9× | ~2× |
| vorbis | 0.00107 | 0.00057 | 1.9× | ~2× |
| dts | 0.00207 | 0.00107 | 1.9× | ~2× |
| mp3 | 0.00132 | 0.00082 | 1.6× | ~1.5× |
| ac3 / eac3 | 0.00132 | 0.00082 | 1.6× | ~1.5× |
| opus | 0.00232 | 0.00157 | 1.5× | ~1.4× |
| tta | 0.00207 | 0.00157 | 1.3× | ~1.2× |
| mp2 | 0.00107 | 0.00082 | 1.3× | ~1.3× |
| wv | 0.00333 | 0.00282 | 1.2× | ~1.2× |
| **wav（引擎地板）** | 0.00057 | 0.00032 | **1.8×** | — |
| speex | 0.00057 | 0.00082 | 0.7×（更快） | — |

\* `decode 增量估 = (era×RT − era_wav地板) / (Stable×RT − Stable_wav地板)`。
**口径局限**：Stable 与 era 走同一 C 壳（float32 PCM 落盘），但解码→输出的字节形态
不完全同构（era 原生位深→convert，Stable ffmpeg 直接出 float）——增量是粗估，只作排序，
不作精确声明。落地前用 `perf` 的 user CPU calltree 复核。

## 3. 差距构成两分（决定先打谁）

1. **引擎公共地板偏高**：连 wav（纯 PCM 拷贝 + 转 float32）都比 Stable 慢 1.8×。
   说明「解码 → f32 交错输出 → 引擎写入」这段公共路径有统一可榨的水分——**改一处，
   全格式受益**（含已封顶的 wav/speex）。候选：中间 `raw` 缓冲的一次多余拷贝、
   convert 每样本函数/除法、写入路径。
2. **codec 纯解码增量差距**：扣掉公共地板后 aac/flac/mka/mp3 仍是 1.5–5×。ffmpeg 的
   优势在解码方案层：预计算表 + f32 + 整数/查表 + 快速变换，era 侧需按格式定位。
   历史上 flac「×RT≈0.02 很慢」最后根因是 io 前瞻缓存而非解码器本体——**教训：先 profile
   再动手**。

## 4. 优化对象候选（perf 定位后按实际命中取舍）

| # | 对象 | 理由 | 风险/纪律 |
|---|---|---|---|
| 1 | **公共 PCM/convert 地板** | 一改全格式受益（§3.1） | 不动语义层；保留「解码原生位深、convert 统一转 f32」不变量（§2.1） |
| 2 | **MDCT/IMDCT 系**（aac 解码+合成、mp3 合成、flac？） | 高频大块变换，ffmpeg 走预计算+快速路径 | 查是否 f64、每点重复算窗/三角；可 `@Vector`/分块；有损容差内 |
| 3 | **Huffman / 位读取**（aac/mp3） | 逐位函数调用可改批量取位/查表 | bit-exact 易验证 |
| 4 | **浮点整肃** | `powf/logf/expf/atanf/sqrtf` 常是隐形大头 → 查表/多项式 | 有损格式须保 corr 纪律 |
| 5 | **mp3 多相合成** | 可换 IMDCT 快速合成 | 保 |corr|≥0.999 / ±≤1 LSB 纪律 |
| 6 | **内存侧（非速度）**：tta 54MB / dts 83MB RSS | scorecard memory 失分全在此 | 整缓冲 vs 固定大缓冲，需 multi-size 判定 |

### 4.1 方向定调（2026-09-10 用户定）：**零新增缓冲，纯计算砍指令**

> 决策：**不采用缓冲/缓存类提速**——不加 Reader 大块预读、不加位流宽缓冲、不加持久
> 中间缓冲。理由：属"作弊"式增益、抬高内核常驻开销、且规避与上游的争端。
> 依据 perf（`PERF_HOT_2026-09-10.md`）：era 与 ffmpeg 的差距是**指令数 2.1–3.4×**
> 而 **CPI 更低**（0.26–0.31 vs 0.42–0.48）——瓶颈是"同功能做了太多指令"，不是访存。
> 因此路线 = **在不新增任何缓冲区/缓存层的前提下削减指令**（寄存器内取位、查表、
> SIMD、分支消除、f32 化、循环不变量外提、算法专用化）。

按 perf 实测热区重排动刀顺序（一次只动一个，§5 纪律）：

| 序 | 对象（perf 热区） | 纯计算手段（无缓冲） | 验收 |
|---|---|---|---|
| ① | **flac 位流 `readBits` ~34% + `io.Reader.read` ~20%** ✅ | 已做：`Reader.readByte()` 单字节快路径（无新缓冲）+ `readBits` 缓存足够快路径 + comptime 掩码表 + `readBit` 直取 | 逐位一致 ✔；perf 指令 **600M→462M（−23%）** |
| ② | **flac 残差/Rice 内层 ~12%** ✅ | 已做：`readUnary1` 缓存内批量数零替换逐位 readBit | 逐位一致 ✔；合成语料指令 461.9M→460.7M（前缀短，收益小） |
| ③ | **mp3 `synthGranule` ~20% + `imdct36` ~7%** ⛔B 档 | 预计算/`@Vector` 属浮点重排（B 档）；按只做 A 档策略暂缓 | — |
| ④ | **aac `decodeIcs` ~39%（谱/Huffman/去量化）** ✅(Huffman 部分) | 已做：Vlc 规范表 O(1)/长度查表（去每长度二分）；去量化查表待评估 | aac 逐位 ✔；m4a 指令 455M→418.7M（−8%） |
| ⑤ | **aac MDCT/FFT ~11%** ⛔B 档 | f32/预计算/SIMD 属浮点（B 档）；按策略暂缓 | — |
| — | 公共 `pcm.convert` ~2% | 低优先（收益小） | — |
| — | mp3 Huffman | 已是 FFmpeg 式直接查表（`codebook[hufPeek]`），无 A 档空间 | — |

**边界澄清（待确认）**：局部寄存器/`u64` 位累加器、SIMD 寄存器、只读常量查表视为
**纯计算**（非"缓冲"）；持久缓冲区/额外预读/缓存层视为禁止项。若"位累加器"亦属禁用，
则 ① 退化为仅精简现有实现的算术与分支（不改取数结构）。

### 4.2 精度安全分层：**只做 A 档 + 三层预计算**（2026-09-10 用户定）

> 决策：提速优化**仅采用 A 档（精度中性）**；B 档（有精度风险）除有损类且经 corr 门禁
> 外，原则上不做；C 档（降位深/近似/偷精度）禁止。

**三档定义（每步按档审查）**
- **A 精度中性**：分支消除 / 循环不变量外提 / 去重复计算 / 去函数调用·vtable·边界检查 /
  整数位运算与查表 / Huffman 单查表 / 把每帧重算的窗·三角·系数改为 **comptime 预计算**
  （同公式同舍入）。**无损类只允许 A 档**，必须逐位一致。
- **B 有精度风险**（仅限有损、且过 corr≥0.999 + ±≤1 LSB 门禁）：浮点重排 / SIMD 浮点 /
  f64→f32 / FMA 重结合 / 快速变换替换 / `powf`→多项式。ac3/eac3/speex 既有欠账不碰。
- **C 禁止**：降位深、跳过校正、近似窗、量化查表偷精度、fast-math 式近似。

**三层预计算（A 档手段，非"缓冲"）**
1. **全局 comptime 表**（进程内 1 份，零运行期增长）：窗/twiddle/Huffman 解码表/pow43 等
   ——若现每帧重算，上提到 comptime 纯赚；
2. **每实例 `prepare`（open 时一次，与解码同 worker）**：按该任务格式/采样率/声道/块类型，
   用**同公式**算派生表/状态；热循环只查表。整数逐位不变、浮点同舍入；
3. **派发 hint**：Master 已知任务类型 → `Task.format_hint`（免 probe 直选 Module）+ 下传
   **预计算计划 ID**，worker `open` 阶段先 `prepare(plan)` 再解码。

**纪律**：预计算产出必须是**只读派生常量/计划**（表、系数），**不得**是数据缓冲、预读输入、
缓存 PCM。禁止把预计算放到与解码**不同**的线程（跨线程搬表=反开销）；即"派发时**要求**
worker 先 prepare"，不是另开线程算。

**启动/开销硬约束（2026-09-10 用户定）**：**即使做了预计算，启动与常驻开销仍必须优于
FFmpeg**（engine-master-pool-design.md §3 启动预算：冷/热首帧 wall 均压 FFmpeg）。
落地要求：
- **comptime 表零运行期成本**（编译期生成、只读数据段）——首选手段，不占启动/内存增长；
- **实例 `prepare` 必须 O(小)、open 时一次、与解码同 worker**，其耗时计入首帧预算；
  预计算后首帧/单流 wall 不得回退到 FFmpeg 基线之上，否则该优化**拒绝**；
- **派发 hint 省 probe**（`format_hint`）是启动净收益，优先；
- 每次优化后复测**冷/热首帧**（`REPORT_ERA_POOL_2026-09-10.md` 口径：冷含引擎 init、
  热复用池）与单流 wall；启动回退即回退该改动。

**验收（每步）**：无损逐位 / 有损 corr≥0.999 且 ±≤1 LSB 不回退；`taskset -c 12 perf stat
-e instructions,cycles` 指令数下降（主指标）；**且冷/热首帧与常驻开销不劣于 FFmpeg
基线**；任一项不过即回退。

## 5. 纪律（验收门，scorecard 已内建）

- **无损类**：输出 f32 PCM md5 与 `flac -d` / ffmpeg 逐位一致（lossless bit-exact）；
- **有损类**：`|corr| ≥ 0.999` 且 ±≤1 LSB（s16 域）不劣化（现 mp3/mp2/aac/dts 已达；
  ac3/eac3 corr 0.96 与 speex corr 0.93 属**既有正确性欠账**，不在提速专项目标内，
  勿混入）；
- 每步重跑 `zig build test`（全量）→ scorecard 全矩阵，看**逐格式 wall 下降**与
  **正确性零回退**；以同轮 CSV 快照判档（跨轮 ±0.5–4 抖动，看分差方向）；
- **新增**：每步同时跑 `taskset -c 12 perf stat -e instructions,cycles` 对同格式同语料，
  确认**指令数下降**（这才是本方向的主指标，而非仅 wall）。

## 6. 第一步（动刀前必做）

```bash
cd app/core/audio-engine
zig build -Doptimize=ReleaseFast && cmake --build build
# 语料 /tmp/eng2 已含 ind.flac / ind.m4a / ind.mp3（scorecard 幂等生成）
perf stat   build/archoera-audio-engine /tmp/eng2/ind.flac --engine-mode 1 --player-file /tmp/o.wav --no-limiter
perf record build/archoera-audio-engine /tmp/eng2/ind.m4a  --engine-mode 1 --player-file /tmp/o.wav --no-limiter
perf report  # 定位热循环 → 对照 §4 候选
```

- 先取 era 与 Stable（mode 0）同文件的 user CPU calltree 对照，确认差距落在**哪段**
  （公共层 vs 具体 codec 函数）；
- 一次只动一个对象，动完即跑 §5 门。
- 工具可用性（2026-09-10）：本机暂缺 `perf`/`valgrind`——先 `sudo pacman -S perf`（cachyos：
  `linux-tools`）或装 `valgrind`；不可用则退化为**探针式热循环定位**（对 §4 候选函数做
  `std.time`/`Io.Clock.awake` 计时打桩跑真实曲目，输出耗时占比定位瓶颈，见文末补充）。
- 关联（2026-09-10）：并发/混杂/资源基准与 scorecard 口径见
  `benchmark-industry-2026-09-05.md`「2026-09-10 更新」与
  `app/core/audio-engine/tests/bench/REPORT_ERA_POOL_SCORE_2026-09-10.md`（FFmpeg=100、5 轮
  去极值、wall/CPU/RSS 入分）；动刀后可用同口径复测并发与单流。
- **perf 结果（2026-09-10）**：`tests/bench/PERF_HOT_2026-09-10.md`——era 指令=Stable
  2.1–3.4×（CPI 更低 0.26–0.31 vs 0.42–0.48 ⇒ 非低效而是**指令多**）。热区（自占比）：
  flac `readBits` ~34% + `io.Reader.read` ~20%（位流≈50%）；aac `decodeIcs` ~39%（谱/
  Huffman/去量化域，MDCT 系 ~11%）；mp3 `synthGranule` ~20% + `readImpl` ~19% + `imdct36`
  ~7%（IMDCT+合成 ≈28%）；公共 `pcm.convert` 仅 ~2%（修正 §3.1 猜测）。Stable libavcodec
  stripped 缺符号，仅总量对照。
  建议动刀序（一次一个，§5 纪律）：①flac 位读批量取位/宽缓冲 → ②公共 Reader 大块预读 →
  ③mp3 IMDCT/多相快速化 → ④aac 谱/Huffman/去量化查表 → ⑤aac MDCT 专用化。

## 7. 与当前工作的关系 / 排期

- **正交**：Module 表/Registry（结构转换）与播放迁池/调度是**并发与生命周期**侧；
  本专项是**单核解码效率**侧。两者共享 `fmt/*`，互不阻塞，可在调度主干落地前后并行。
- 建议排期：**先动 §4 #1（公共地板）**，收益全格式、改动集中；codec 侧（#2–#5）
  在 perf 指认后按「差距大 × 命中明确」逐个攻（aac/adts、flac/mka 优先）。
- 本文件为工作稿，命中数据与结果回填后升级为定稿。

## 8. 复现

```bash
cd app/core/audio-engine/tests/bench
python3 scorecard.py --corpus /tmp/eng2 --csv data/SCORE_$(date +%F).csv \
    --md SCORE_$(date +%F).md --build-tag <tag>
```

> 机器/工具/口径与已知抖动见 `benchmark-industry-2026-09-05.md` §4/§7（i9-13980HX、
> zig 0.16.0、ReleaseFast kernel、单轮 RSS/wall 采样抖动 ±0.5–4 分——看 era vs Stable
> 的**分差方向**而非个别行绝对分）。
