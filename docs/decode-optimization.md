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

## 5. 纪律（验收门，scorecard 已内建）

- **无损类**：输出 f32 PCM md5 与 `flac -d` / ffmpeg 逐位一致（lossless bit-exact）；
- **有损类**：`|corr| ≥ 0.999` 且 ±≤1 LSB（s16 域）不劣化（现 mp3/mp2/aac/dts 已达；
  ac3/eac3 corr 0.96 与 speex corr 0.93 属**既有正确性欠账**，不在提速专项目标内，
  勿混入）；
- 每步重跑 `zig build test`（全量）→ scorecard 全矩阵，看**逐格式 wall 下降**与
  **正确性零回退**；以同轮 CSV 快照判档（跨轮 ±0.5–4 抖动，看分差方向）。

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
