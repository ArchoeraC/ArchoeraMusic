# FLAC 专修：调研与计划

> 状态：**调研稿 v1 · 2026-09-22**
> 定位：`audio-kernel-expansion-plan.md` §5.2 P1 已修好**公共 PCM 地板**，但 **FLAC 几乎没吃到**
> （`decode-optimization.md` §9：指令数仅 −0.8%，当前仍约 **6.2×** 于 FFmpeg）。本文专攻 FLAC 自身。
> 前置：有损 B 档（MP3/AAC）先行；本文为**无损**格式，**bit-exact 强制**。

---

## 0. 为什么 FLAC 没吃到 P1

| 现状 | 说明 |
|---|---|
| 位流逐字节 | `kernel/fmt/flac/bitreader.zig`：`fetchByte()` **每次只取 1 字节**，`bits_avail ≤ 8`；`readUnary1` 只在 8 位缓存内数零 |
| 每字节两次 CRC | 每次 `fetchByte` 都 `crc8Update` + `crc16Update`（两次 256 项表查）→ 热路径里占比很高 |
| LPC 标量点积 | `subframe.zig decodeLpc/decodeLpcWide`：每样本 `for (coeffs, hist) sum += c*smp`，无展开、无向量化 |
| 去相关标量 | `lib.zig decorrelate / decorrelate33`：逐样本整数运算（对照 `flacdsp_template.c`） |
| 热路径不经过 P1 | flac 走 `readByte`/自建位缓冲，不经过被修的 `readFile` 字节循环，只吃到 `convert` 的微小收益 |

**结论**：FLAC 专修的主战场是 **位流层（含 CRC）** 与 **LPC/去相关的整数向量化**，二者都可在
**bit-exact** 前提下完成。

---

## 1. 上游可迁移技术（出处 → 我们）

> 纪律：**只借鉴算法**；我们自己的符号不得与上游逐字相同（内核转写表/常量用 `era_` 前缀）；
> 注释可注明出处。许可登记见 `app/core/audio-engine/THIRD-PARTY-LICENSES.md`。

### 1.1 位流：批量缓存 + word 级 CRC
- **FFmpeg `GetBitContext`**（`libavcodec/get_bits.h`）：32/64 位位缓存 + `UPDATE_CACHE`/`SKIP_BITS`，
  一次 refill 取多个字节；解码在**已知帧**的 buffer 上进行，CRC 在帧末对 buffer 段一次算完。
- **libFLAC `bitreader.c`**：word 级 refill；`FLAC__crc16_update_words32/64`（按字更新 CRC-16，
  减少每字节函数调用）。
- **dr_flac**：64 位缓存 + 指针推进。
- **迁移到我们**：`io.Reader` 有 **`peek(buf)`（不消费 `pos`）** 与 `readAt`/`read`。可以：
  1. 位缓存升级为 **u64**，用 `peek` 一次取 8 字节（复用 `io.Reader` 既有 16 KiB 缓冲，**零新增缓冲**）；
  2. **CRC 只对「已被位游标消费的字节」计算**（懒 CRC），从而允许安全预读；
  3. 帧末按**实际消费字节数**推进底层 `pos`（从 peek 缓冲 `read` 掉；无新 I/O）。
  > 这正好绕开现设计「逐字节取以保证 CRC 精确、不预读下一帧」的根因，同时不破坏不变量。

### 1.2 Rice / 残差（`residual.zig`）
- 用 **u64 缓存 + `@clz`** 一次数出前缀零（替代 8 位循环）；`u = (i<<k) | tail` 与符号折叠不变；
- escape 路径、分区循环、`pred_order` 跳 warm-up 语义保持（对照 `flacdec.c decode_residuals`）。

### 1.3 LPC / Fixed（`subframe.zig`）
- **FFmpeg `flacdsp.c`**：
  - `flac_lpc_16_c`：**2 路展开**（`s0`/`s1` 交替）打破逐样本顺序依赖——**纯标量、bit-exact**，收益直接；
  - `flac_lpc_32_c` / `flac_lpc_33_c`：i64 点积，x86 侧由 `ff_flacdsp_init_x86` 上 SIMD；
  - `flac_wasted_32/33_c`：wasted-bits 左移。
- **libFLAC `lpc.c`**：`FLAC__lpc_restore_signal*` 按 order 展开实现。
- **迁移到我们**：
  - fixed 0–4 阶（预测系数固定）**展开**；
  - LPC：内层点积用可移植 `@Vector`（系数向量 × 历史样本向量）做 i64/iu32 累加，
    **保持与现有相同的累加宽度与截断**（`sum >> qlevel`、`decoded +=`）；
  - 33-bit 路径注意无符号环绕语义（对照 `flac_lpc_33_c` / 现有 `decodeLpcWide`）。

### 1.4 立体声去相关（`lib.zig`）
- **FFmpeg `flacdsp_template.c` `flac_decorrelate_{indep,ls,rs,ms}_c`**：纯整数；
- 迁移：`@Vector` 批量（16/32/33-bit 各自的环绕语义逐位对齐）。

### 1.5 CRC（`crc.zig`）
- **libFLAC `crc16_update_words32/64`** 思路：按字/多字节 unrolled 更新，减少调用与表查次数；
- 与「懒 CRC（只算消费字节）」配合，位流层一次算一段。

---

## 2. 红线与门禁（无损，严格执行）

- **bit-exact 强制**：每步改动的引擎输出 **md5 与改前逐位相同**；并对 FFmpeg 解码参考 **逐位一致**
  （无损不适用 corr 门禁——必须 0 误差）。
- **零新增缓冲**：仅复用 `io.Reader` 现有 16 KiB 缓冲与寄存器位缓存；不引入整帧/大块中间缓冲。
- **首帧/常驻不劣化**：`bench_coldstart` 冷/热首帧与 open/create 不劣于改前。
- **回归**：`zig build test`（当前 676/676）不回退、不新增失败（≥5 个不同 seed 连跑）；
  `ctest` 22/22；`zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast` 通过。
- **可移植**：只用 `@Vector`/`std.simd`/标量技巧，**不引平台 intrinsic**；零新依赖。
- **命名**：新符号自有；转写表/内部常量 `era_` 前缀；注释可溯源。
- **度量**：`tests/bench/insn_count.c` 取 flac 指令数/墙钟/cycles，**分步**记录。

---

## 3. 分步执行计划（每步单独过门禁，不达标即回退）

| 步 | 目标 | 文件 | 预期 |
|---|---|---|---|
| FL-1 | 位缓存 u64 + `peek` 批量 refill + 懒 CRC + 帧末 drain | `bitreader.zig`（+ `io.zig` 只读复用 `peek`） | **最大收益**（当前逐字节+双 CRC 为主瓶颈） |
| FL-2 | Rice 前缀改 `@clz`（64 位），escape/分区语义不变 | `residual.zig` | 中 |
| FL-3 | LPC 32/33 内层点积向量化 + fixed 0–4 阶展开 | `subframe.zig` | 中～大 |
| FL-4 | 立体声去相关 `@Vector`（indep/ls/rs/ms，16/32/33） | `lib.zig` | 中 |
| FL-5 | CRC word 级 unrolled（配合 FL-1 懒 CRC） | `crc.zig` + `bitreader.zig` | 中 |

> 每步：先 `insn_count` 取改前值 → 小改 → `md5 前==后` + FFmpeg 逐位 + 多 seed 测试 + ctest + 交叉编译 →
> 记录 Δ；不达标回退。**FL-1 风险最高**（peek/drain 与 seek/错误恢复、CRC 精确性），放首位并重点复核。

---

## 4. 风险与验证要点

- **CRC 精确性**：必须只对「位游标已消费」的字节做 CRC；帧末不得把预读的下一帧字节计入。
  验证沿用现有 `bitreader` 测试（帧头 CRC-8、整帧 CRC-16 == 0、`r.pos == 帧长`，不预读下一帧）。
- **seek/错误恢复**：懒 CRC + 预读会改变 `reader.pos` 的推进时机；错误路径必须让 `pos` 与已消费字节一致，
  否则 resync 错位。用现有 seek/EOF 测试 + 新增「中途 error 后 seek 重解」用例覆盖。
- **整数语义**：LPC/去相关的累加宽度、移位与截断必须与改前逐位一致（尤其 33-bit 路径的无符号环绕）。
- **可移植性**：`@Vector` 在 SSE2 基线与 Windows 目标下的降级不得影响 bit-exact；仅影响速度。
- **回退**：任一步不达标即回退该步，保留最干净 diff。

---

## 5. 验收

- flac 指令数相对改前显著下降（目标数量级：接近或优于 FFmpeg 方向；不预设硬指标，按步记录实际）；
- 全程 **bit-exact**（md5 与 FFmpeg 参考）、首帧不劣化、676/676（多 seed）、ctest 22/22、Windows 交叉通过；
- 结果回填 `decode-optimization.md`（新增 FLAC 专修小节）并与本文件对照。
