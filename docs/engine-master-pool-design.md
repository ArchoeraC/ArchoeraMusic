# 引擎主控 + 调度池设计（完整 Zig 内核）

> 状态：**设计定稿（2026-09-08）· 未实现**
>
> 定位：本文件把「进程内模块化引擎」从「纯函数内核 + C 壳外挂线程」演进为
> **一个完整的 Zig 内核**：**主控（Master）+ 调度池（Pool）+ 模块注册表（Registry）**
> 全部在 Zig 内、自持线程。它取代/落地的前身与约束来源：
>
> - **取代** `docs/engine-master-worker-scheduling.md`（"主控 Async × 模块线 Sync +
>   完成即领"调度稿）——本文件是它的**架构落地**，回收/伸缩语义被重定为
>   **eager+lazy+hybrid 三态 init + worker 状态注册表**（见 §5）；
> - **落地** `docs/audio-kernel-zig.md` §8.4 / §8.4.1 / §8.4.2（Phase G：模块化 +
>   A/Sync 执行模型 + 优先子项）——本文件给出可编译的模块/线程结构；
> - **修订** `docs/audio-kernel-zig.md` §16.1 的「内核不持线程」不变量（见 §2 修订说明）；
> - 与 `docs/audio-memory-playback.md` / `docs/audio-memory-source.md`（PCM/源内存
>   语义）无关，但调度池可承载其 128 路并发诉求。

---

## 1. 核心定位（先定死）

- **完整 Zig 内核**：主控 + 调度池 + 注册表**都在 Zig 内**，由 Zig 自持线程运行；
  不再要求"内核零线程、由 C 壳驱动"。
- **主控（Master）＝双能力**（不是"纯异步事件循环"）：
  - **同步能力 · 线程生命周期**：`kernel_init` 阶段同步建 eager 保底 worker；回收 /
    停机时同步 `join`。线程的创建与回收是确定性操作，**归 Master 同步执行**。
  - **异步能力 · 任务派发**：自持 1 事件线程，运行期事件驱动做 **submit 受理 →
    Registry 探测/分派 → 簿记（cap/护栏）→ 完工处理 → 伸缩决策**。
  - 分界：**"何时需要建/收线程"是异步决策**（事件循环内判断），**"实际 create/join"
    是同步动作**（在事件线程内直接执行，创建/回收均轻量可短阻塞）；见 §3.1。
  - Master 自身**不做解码**。
- **分工锚点（全文可记忆的一句话）**：**凡可能失败 / panic / 卡死的活交给 worker
  （解码 / 实例 open / 缓冲分配 / spawn 的脏活）；Master 只做不会失败的最小簿记
  （位图查槽 / registry 读写 / 带超时 wait）**。脏活崩了换 worker；Master 会崩的
  唯一理由是内核 bug → 宿主重建。详见 §5.4。
- **调度池（Pool）**：M 条 Sync worker（OS 线程，全 Zig `std.Thread`），分到任务后
  在线程内**同步逐帧解码**（单流帧级串行，天然正确）。
- **模块注册表（Registry）**：probe → 按格式选只读 `Module` → 开/收实例 `Instance`；
  只读能力表 + 簿记（实例计数 / cap / fd·内存护栏）。
- **init 三态（eager / lazy / hybrid，Linux workqueue 式思路）**：
  - **eager**：常驻保底 worker + 预建模块（覆盖单流播放等"必在"路径）；
  - **lazy**：短任务（批量 tag / metadata）按需开实例、即收即放；
  - **hybrid**：worker 池随负载**动态伸缩**——负载高新建、长时间空闲回收，
    由 Master 决策（worker 自提交 + Master 询问，见 §5）。
- **同步直通保留**：现有 `zk_decoder_open/read/seek/close` 同步入口**保留**作回归/
  单流稳定基线；Async Master/Pool 为并发主干。两者共享同一 Module/Instance/fmt
  只读层，仅"谁驱动实例"不同（见 §7）。
- 子任务种类**不预设**（沿用 scheduling 稿 §2.1）：decode / transcode / metadata
  首批，可扩展。

---

## 2. 不变量与既有约束的修订

### 2.1 修订「内核不持线程」（§16.1）

`docs/audio-kernel-zig.md` §16.1 原文「**Zig 内核本身不持线程，仅被 C 壳调用**」
及 `kernel/engine.zig` 头注释「本模块不持线程」→ **修订为**：

> **Zig 内核自持调度线程**：Master 事件线程 + Pool worker 由 `kernel_init` 创建、
> `kernel_shutdown` 统一 join。`fmt/*` 模块与 `Decoder` 仍保持**纯 Sync 语义**
> （无内部线程、无 async 状态机），仅被 Pool worker 线程驱动。

保留的（**不修订**）：
- 模块**全局只读**、实例**私有可变**（§8.4 不变量 1）——128 路互不污染的根基；
- 单流内**不做帧级并行**（§8.4.1）——MP3 Huffman/FLAC 预测/Opus 状态依赖串行；
- **零拷贝边界**（§8.4 不变量 3）：Sync-Direct 单线程内才可能零拷贝；跨线程移交
  packet 必须拷贝。

### 2.2 与 `engine-master-worker-scheduling.md` 的关系

该稿的「主控 Async × 模块线 Sync + 完成即领」仍是**执行形态的语义**，本文件沿用；
本文件的增量是**资源生命周期**（eager/lazy/hybrid）与**回收决策结构**（worker 状态
注册表 + Master 询问），并把线程实现在 Zig 内核内。旧稿保留作"调度语义说明"，
其 §2.2（M/线程参数）、§2.3（scanner 接线）、§2.4（Bus）继续有效。

---

## 3. 总体架构

```
宿主 / C 壳（Dart FFI 面基本不变）
   │  kernel_init(cfg) / submit(Task) / wait_event / kernel_shutdown
   ▼
┌─ Zig 内核（常驻；自持线程）───────────────────────────────┐
│                                                            │
│  Master（Async 事件线程 ×1）                                │
│   │ 职责：接受 submit → Registry 探测/分派 → 簿记(cap/护栏) │
│   │       → 派发到 Pool；收 worker 完工/可回收事件；伸缩决策 │
│   │                                                            │
│   ├── Registry（probe → Module → Instance）                  │
│   │      Module：fmt/* 只读能力表（进程内每格式 1 份）          │
│   │      Instance：decoder.Decoder（每模块 0..N）              │
│   │                                                            │
│   │  Worker 状态注册表 registry[worker_id]（§5）              │
│   │                                                            │
│  Pool（M 条 Sync worker；M 由 cfg + 动态伸缩）                  │
│    ├─ 短任务：完成即领（向 Master 报完工 → 领下一件）            │
│    └─ 长流：按流分配 + 每 worker 持 1..K 路帧级分时              │
└──────────────────────────────────────────────────────────────┘
```

- 启动：`kernel_init(cfg)` 建 Master 事件线程 + eager 保底 worker + Registry。
- 退出：`kernel_shutdown()`：Master 停收新任务 → 通知 worker → join 全部 →
  释放模块表/注册表。
- 通道：Master ↔ 宿主 事件 **复刻现有 wait_event 推模式**（condvar/ring）；
  Master ↔ worker 用内部 condvar / 空闲栈 / 原子，一次最小握手（不做零同步）。

### 3.1 Master 双能力：同步线程生命周期 × 异步任务派发

> 澄清（2026-09-08 用户定）：Master 不是"纯异步事件循环"。它同时具备两副能力，
> 且二者分界清晰——**决策异步、动作同步**。

**能力 A —— 同步 · 线程生命周期管理**
- 线程创建是确定性、轻量的系统动作：`kernel_init` 阶段同步创建 Master 事件线程与
  eager 保底 worker。
- hybrid 扩容：**决策在 Master 事件线程内做**（§5.4 无失败路径），但**实际 `spawn`
  可由低优后台执行或就地尝试**——spawn 失败不 panic（§5.4），仅记日志、任务继续
  排队等待空闲 worker；保底 eager worker 保证播放不被 spawn 失败影响。
- 线程回收与停机是确定性动作：回收决定后由 Master **同步 join** 已退出的 worker；
  `kernel_shutdown` 同步 join 全部线程。
- 归 Master 管：worker **不自建、不自杀**（不自杀 = 不自行 `exit`，退出由 Master
  驱动后 worker 收尾返回）。

**能力 B —— 异步 · 任务派发与伸缩决策**
- Master 事件线程运行期**等待事件**（submit / worker 完工 / worker 可回收 / 超时），
  事件到来才处理：受理任务 → Registry 探测/分派 → 簿记 cap → 决定是否扩容/回收。
- 空闲时**不忙等**（condvar/ring 阻塞），不占解码线程。

**分界（为何可共存）**
- "**要不要**建线程/收线程" = 异步决策，在 Master 事件循环里做；
- "**去执行**创建/join" = 同步动作，在 Master 事件线程内直接做（轻量、可短阻塞）。
- 因此"主控 Async"与"线程 init 归主控同步执行"**不矛盾**：前者是决策形态，
  后者是动作归属。

**表面同步、内里异步（对调用者视角）**
- 宿主 `submit(…)` 立即返回 → Master 异步派发 → worker 并行解 → 完工事件
  wait_event 推回 → 宿主阻塞 `wait` 到完工：**对外封装成一次"看似同步"的解码请求**，
  内部是 Master 事件驱动编排 + M worker 真并行。
- 但**解码本身恒 Sync**（worker 内 `Decoder.read()` 同步逐帧）；异步只存在于
  Master 编排层，不是帧级协程。

---

## 4. init 三态与线程伸缩

| 态 | 含义 | 应用 | worker/实例生命周期 |
|---|---|---|---|
| **eager** | 常驻预建 | 单流播放（保底 1 常驻 worker）、模块表预载 | 池内保底 worker 不回收；模块表进程内 1 份 |
| **lazy** | 按需开、即收即放 | 短任务（批量 tag/metadata/decode 单发） | 实例"开→解析→关"，Master 只登记不缓存 |
| **hybrid** | 动态伸缩（Linux workqueue 式） | 批量/128 路高峰 vs 低谷 | 负载高 Master 新建 worker；长闲 Master 回收 |

**播放路径覆盖**（回答"调度池能否覆盖播放"）：单流播放走 **eager 保底 worker**
（M_min=1 常驻，等价现有"1 会话 1 线程"但不劣化），因此调度池在 M=1 时即为
播放专用；批量/128 路时 M 动态升。**无需为播放另开直通通道**——hybrid 下保底即
直通。

---

## 5. Worker 回收：注册表 + Master 询问

**决策结构（用户定：每格自写 + Master 读，类比 Windows 注册表的极轻量版）**：

> 与 §6.2「槽位表」的分工（避免两个"格子"混淆）：
> - **worker 状态注册表 registry[i]**：以 **worker（线程）** 为键——记录线程的状态
>   （idle/busy/retiring），供**回收决策**与**空闲集合查询**；
> - **槽位表 slots[s]**：以**任务执行位**为键——记录任务/实例绑定，供**派发与重派**；
> - 一个活跃 worker 同时挂在一个槽上：registry 管"线程活着没、空不空"，slots 管
>   "这个位在跑什么任务"。回收线程动 registry；重派任务动 slots（换线程不换槽）。

- 一块**集中 worker 状态注册表**：`registry[i]`（i = worker_id）一条记录，**该
  worker 独占写**（自提交），Master 只读聚合。
- 记录字段（草案）：`state: idle | busy | retiring`、`idle_since_us`、
  `reclaimable: bool`、`task_ref?`（长流任务句柄）。
- 写：worker 每进入空闲/开工/将收尾更新自己的格子（单写者，无锁 / 原子足够）；
  **worker 自提交**「我已空闲 idle_since 起 / 我可回收」。
- 读：Master 事件循环仅在**被事件唤醒或带超时 wait 到点**时**询问**注册表，
  聚合出"哪些 worker 空闲超过阈值"，逐个发回收信号（时序协议见 §5.1）。
- 语义：**回收不统一进行**（不做"全部空闲后一起收"）；每个 worker 各自在
  "长时间空闲"后经注册表可回收 → Master 逐个回收（发 `retire` → worker 收尾 →
  join）。

**为何不做"全部线程无任务后统一回收"**：统一回收把"线程数"当整体开关，无法表达
"保底常驻 + 弹性伸缩"；每 worker 自提交 + Master 询问能精确表达 eager/lazy/hybrid
的混合需求（播放保底 worker 永不 reclaimable，批量高峰外的空闲 worker 逐个回收）。

---

### 5.1 状态同步与唤醒协议（谁等谁、何时醒；Async↔Sync 互通）

> 注册表只回答「**对方现在是什么状态**」（决策时读一次）；它不回答「**什么时候变了、
> 该叫醒谁**」。唤醒与有界等待由本节的**事件通道 + 两处有界等待**协议补齐。

**双通道（状态与事件分离）**

| 通道 | 内容 | 写 | 读 | 语义 |
|---|---|---|---|---|
| **状态格** registry[i] | state / idle_since / task_ref / reclaimable | 该 worker 独占写（无锁/原子） | Master 只读聚合 | "现在是什么"——决策依据 |
| **事件通道**（condvar / 信号） | 完工 / 我空闲了 / 可回收 / 派发 / retiring | 任一方 | 另一方 | "发生了什么、该叫醒谁"——唤醒依据 |

- Master **不主动盯格**：worker 完工/空闲时发事件把它叫醒，Master 醒后才读格决策。

**两处有界等待（谁也不永久等）**

- **worker 空闲**：阻塞在自己的 `cv` 等 Master 消息（派发 / retiring / shutdown）；
  **不自设超时、不轮询、不自杀**。不会永久等——Master 对它必有动作（派活 / 回收 /
  停机），由 Master 保证。
- **Master 空闲**：阻塞在 `master_cv` 等事件（宿主提交 / worker 完工 / shutdown），
  **带超时 = 距「最早可回收点」的时刻**。超时醒 → 询问注册表 → 对超时 idle 的
  worker 逐个发 retiring → 回到阻塞。

**Async 回收触发如何界定（非周期 tick）**

- 回收触发点不是固定周期，而是 Master 单点算出
  `next_check = min(idle_since + idle_timeout)`，只睡到那一刻；
- 到点回收一次，然后回到带超时阻塞。**零轮询**：这是"下个事件必然发生的时刻"
  的带超时等待，不是周期扫描，不拖慢内核。

**不回收正在运行的线程**

- **state 先行更新**：worker 开工前先把格置 `busy` 再执行；空闲前先把格置
  `idle + idle_since` 再进 cv。Master 只回收 `state == idle && 超时` 的 worker，
  `busy` 永不进候选。
- **回收单一所有者 = Master**：只有 Master 读格 + 发 retiring，无"两个回收者抢同一
  worker"竞态。

**零轮询汇总**

- worker 空闲 = condvar 真睡眠（CPU 0）；Master 空闲 = 带超时 condvar 真睡眠；
  状态 = 无锁/原子共享内存只读一次，不忙等。

**派发：无指定线程，Master 自主决策（并依赖 Async 启动）**

- worker 完工 → 写格 `idle` → 发「空闲」事件；
- Master 收到事件 → 若有排队任务，**选任意空闲 worker**（空闲集合线索 =
  registry 中 idle 的 id / 槽位表空闲位，见 §6.2 一致性）→ 写格 `busy + task_ref`
  → signal 该 worker cv → worker 醒去执行；
- 若 submit 时无空闲 worker：**hybrid 决策**——Master 读 registry 统计 busy 数 vs
  队列深；未达 max M 且积压 → Master 在事件循环内**同步 spawn** 新 worker
  （worker 不自建）；新 worker 入 idle 格，Master 再把排队任务派给它。
- 线程选择 = Master 从空闲集合任意取；线程创建 = Master 按负载 spawn——都在
  Master 单点，不依赖调用方指定线程。

**「完成即领」与「等 cv 阻塞」的统一模型（消除 pull/push 表述冲突）**

- 调度稿的"worker 干完即向 Master 领下一件"与本节"Master 派发 + worker 等 cv"
  不是两套模型，是**同一模型的省唤醒两步**：
  1. worker 完工 → 写格 `idle` → **先无锁 peek 一次**是否有排队任务：
     - 有 → 直接写格 `busy + task_ref` 继续（**省一次 Master→worker 唤醒往返**）；
     - 无 → 才进自己的 `cv` 阻塞（把 `idle` 让 Master 可见，供回收/再派）。
  2. Master 此后收到 submit/完工事件 → 从 idle 集合取 worker → 写格 + signal 唤醒。
- 语义等价"完成即领"，但省掉"必先唤醒 Master 再由 Master 唤醒我"的最坏两跳；
  与 §5.4（Master 定容无失败）一致：peek 只读位图/游标，O(1)、零分配。

**「自领」与「被回收」的竞态消解**

- 隐患：worker 置 `idle` 后先 peek（A 模型）可能正想自领，Master 却见其 idle 超时
  欲发 retiring——两者对同一 worker 冲突。
- 消解：**peek 自领与 idle 置位之间用同一把短锁/原子段**（Master 读 idle 判回收也走
  同一临界区）。worker 在临界区内决定"自领 or 进 cv"；Master 在临界区内决定
  "再派 or retiring"。二者互斥，结果唯一：worker 要么拿到任务、要么进 cv 等被派、
  要么收到 retiring 收尾——不会出现"worker 自领了任务又被回收"。
- 保底常驻（eager）worker 在临界区直接跳过"可回收"分支（reclaimable=false，
  §5），永不进入 retiring 候选。

---

### 5.2 故障模型：崩溃 / 卡死 / 主控失联

> 补 §5.1 的隐含假设：worker 置 `busy` 后**未必能完工并回报**——任务可能故意
> 崩溃（panic）或死锁/卡死。分三层，且**「Master 事件线程永不阻塞」是首要设计约束**。

**层 1 · 崩溃（panic）——正解是"不让 panic 发生"，不是"回收线程"**

- Zig panic 默认 **abort 整进程**，进程内无法安全恢复单线程（可能正持锁 / 写共享态）；
  因此不做"panic 线程回收"。
- **解码路径零 panic**：一切畸形 / 截断 / 恶意输入走 **error 返回**（现状 fmt 已遵循
  error set 纪律），绝不 `panic` / `unreachable`。任务结果带 `error` 回报 Master →
  Master 正常回收 worker、上报宿主。"故意搞崩溃的任务"在正确实现下 = 一个 error 任务，
  不是线程事故。
- panic 视为**内核 bug**（非运行时态）→ 保持 abort 语义，由**宿主级重建**兜底（层 3）；
  防线前移 = 零 panic 纪律 + fuzz 保证。

**层 2 · 卡死（deadlock / hang）——锁纪律消除主因，last-activity 停滞判定 + 放弃兜底**

- **设计上不死锁**：模块只读 + 实例私有 → 解码路径几乎零共享锁；共享区仅
  registry / 簿记（短临界区、单一锁序）。死锁主因在设计层被消除。
- **IO 阻塞可断**：卡在 `Reader` 阻塞（网络 / SegStore）→ `Reader.abort()` 中断
  （对齐 §13.1），能救。
- **残余长任务 / 真死锁 → last-activity 停滞判定 + 放弃 worker**：
  - **判定不是"完成时限 deadline"**（同类任务不同线程耗时差异大，统一时限会误杀
    慢线程），而是**"长时间无推进"**：worker 每次推进（产出事件 / PCM / 位置）时写
    **槽位 last_activity 原子时间戳**（一次 store，近零成本）；
  - Master 带超时 wait 醒来时扫描：`stalled = now − last_activity > stall_timeout`
    ——有推进就不判死，无推进超时才判死（活动性超时，非完成时限）；
  - 判死后：实例私有 → **放弃即泄漏该实例内存**（单次可接受），registry 格复位、
    新 worker / 预留槽位顶替；
  - 真死锁线程**不能 join（会永久 block Master）、也不能在锁内 cancel** →
    **detach**；代价是占一个 OS 线程（锁纪律保证不会普遍发生）。

**层 3 · 主控失联 —— 不做"重启 Master"，做"重建整个常驻内核"**

- **首要防护：Master 事件线程永不阻塞**——`join` / 重活踢出事件线程（worker 收尾后
  自报 joined，Master 只收结果）；Master 不做解码、不做大分配、不 join；临界区只读
  格 + 短簿记。Master 自身低危、不自死锁。
- **主控高优先级**：Master 事件线程设高调度优先级（RT / 最高 nice 档），保证带超时
  wait 唤醒及时、不被调度饿死（独立于检测方案，是可靠性前提）。
- **兜底看门狗（宿主侧，非内核周期心跳）**：宿主（C 壳 / Dart）是最终权威——
  `kernel_ping(timeout)` 可超时查询（**宿主主动查，不是内核周期发心跳**）。宿主发现
  失联 → `kernel_shutdown_force` + `kernel_init` **整库重建**（Dart 重启播放会话）。
  "实时重启 Master"不在进程内做；进程内极限 = 重建常驻内核实例。

**为什么不用独立心跳 / 统一 deadline**

- **心跳**是周期资源（唤醒 + 簿记），且我们本就在 Master 带超时 wait 里做扫描——把
  "查卡死"嵌入这次扫描（§5.1），零新增周期成本；worker 侧只有"推进时写一次
  last_activity"这一近零 store。
- **统一 deadline**误杀慢线程（同类任务无法保证同时完成）——用"无推进超时
  （stall_timeout）"更准：只要在推进，多慢都不判死。

**汇总**

| 故障 | 判定 | 处理 |
|---|---|---|
| panic | 解码路径零 panic（只 error） | error 回报→正常回收；真 panic=bug→abort+宿主重建 |
| IO 卡死 | worker 不回报 | `Reader.abort()` 中断 |
| 死锁/长任务 | `now − last_activity > stall_timeout`（停滞，非 deadline） | 放弃实例+detach worker+预留/新 worker 顶替 |
| Master 失联 | 宿主 `kernel_ping` 超时 | `kernel_shutdown_force`+`kernel_init` 整库重建 |

---

### 5.3 对抗性任务防御：黑名单 / 危险等级 + 难度预留替换

> §5.2 处理"单次故障"；本节处理"**蓄意对抗**"——任务绕过 worker/Master 自保护直击
> 线程（内存破坏 / 无限循环 / 卡死在主控不可见处），并防止**同一恶性任务被二次分派**。

**威胁模型**：§5.2 的 last-activity 停滞判定（`now − last_activity > stall_timeout`）
已能兜住普通卡死；但对**故意注入**（如畸形输入触发解码路径越界 / 恶意长任务）——
故障会复发、同一输入会被重扫/重派。需要**分派前过滤（黑名单）** + **替换低延迟
（难度预留）**。

#### 黑名单 / 危险等级（分派前过滤）

- **键 = 任务指纹**：`{source(path/URL/memory hash), kind, format}` —— 同一输入同
  指纹；命中即拦，杜绝完全相同的恶性任务重派。
- **危险等级记录**：每次故障（§5.2 判定）给该指纹等级 +1 并记冷却；复发升级，
  达到阈值永封并上报宿主。
  - `level` 决定分派策略：低危＝照常但该指纹冷却期不再接同源；中危＝仅一次性观察
    分配；高危＝拒绝分配 + 上报。
- **存储实现（先评估，倾向自建极轻量并发存储）**：
  - 规模=坏任务数，量小；查询=分派前一次查找；写=事件触发；schema 固定 → **通常
    无需引入通用数据库**。
  - 若确需持久化/跨会话记忆，倾向**自写支持并发的极轻量存储模块**（对齐 registry
    的"每格自写/Master 读"思路：指纹哈希 → 记录，无锁/原子 + 分片），保证绝对性能，
    不引入外部 DB 依赖。
  - 备选：宿主侧维护（Dart/文件）持久化黑名单，内核只持进程内热表。
- **分派前检查**：Master 受理 `submit` 先查黑名单 → 命中拒绝（error）/ 隔离观察。

#### 难度预留替换（防替换延迟与复发）

- 坏线程替换不能等"现场 spawn"（延迟窗口 = 攻击面）。**Master 按当前任务难度自动
  预留 worker**：
  - 按任务难度（预估时长 / 复杂度 / 历史该格式耗时）维护**预留水位**：常备少量
    idle worker 池，必要时（detach 坏 worker 后）**直接取预留顶替**，不现 spawn；
  - 预留水位随难度/负载自动伸缩（hybrid 之上的一层"安全垫"）；恶意复发时同样走
    §5.2 替换，但由预留池即时补位。
- **与 §5.2 关系**：§5.2 处理单次卡死（detach+spawn）；本节把"spawn"改为"取预留"，
  并把故障来源记入黑名单防止复发——两者叠加 = 单次可救 + 复发被拦 + 替换即时。

**开放项**
- 黑名单存储最终形态：进程内热表 / 自写并发存储模块 / 宿主持久化，落地时按
  §8.4.2③ 基准数据定（是否需要跨会话持久化）。
- 危险等级阈值、冷却时长、预留水位系数——真机校准后落常量（对齐 §6.1 minFloor
  式"校准后以常量落库"的做法）。

---

### 5.4 Master 无失败定容簿记（Linux 调度器式；主控自身不 panic）

> **分工锚点**：凡可能失败 / panic / 卡死的活交给 worker（解码 / 实例 open / 缓冲
> 分配 / spawn 的脏活）；Master 只做**不会失败的最小簿记**（位图查槽 / registry 读写 /
> 带超时 wait）。worker 崩了 → 换 worker（§6.2）+ 任务重跑（§5.3）；Master 唯一会崩
> 的理由是内核 bug → 宿主重建（§5.2 层3）。

> 担忧（2026-09-08 用户）：主控可能因"过多任务 / 无法分配 / 无法启动 / 不知怎么
> 分配"而自己 panic → 整个音频内核挂掉，看门狗也难救。
> 解法不靠"让主控更健壮地 panic"，而是**让主控处于"结构上不可能做危险操作"的位置**——
> 对齐 Linux 调度器（`schedule()` 只搬指针不分配、核心对象预分配常驻、满即拒不扩容、
> O(1) 确定决策、复杂活踢后台）。

**Master 只做簿记，绝不执行会崩的工作**
- 解码全在 worker；Master 事件循环只做「查槽 + 簿记读写 + 带超时 wait」（§3.1）。
- worker 崩/坏由 §5.2/§5.3 处理（detach/重派/黑名单），不伤 Master。

**kernel_init 一次性预分配定容簿记（no-alloc / no-fail）**
- 槽位表 / 任务表 / registry / 空闲位图全部**固定容量**（cap = 实例上限），
  `kernel_init` 时一次分配完毕；
- 运行期 **Master 关键路径零堆分配**（对齐 Linux `GFP_ATOMIC`/不分配手法）——分配
  可能失败的场景被设计为"不在 Master 关键路径发生"。

**固定容量满即拒，不扩容**
- 表满 → `submit` 直接返回 `InstanceLimit` / 队列满错误，**绝不尝试扩容**
  （扩容=分配=失败点，从 Master 移除）。
- "任务过多"不再是 Master 崩溃源，而是"拒新任务 + 簿记"的正常路径。

**启动可能失败 → 视为非致命，不在 panic 路径**
- worker spawn、实例 open、reader 缓冲分配等**可能失败**；失败回报 error / 记日志
  （任务排队等空闲 worker），**绝不 panic**——失败点从"会崩 Master"变成"可处理
  的非致命结果"（§3.1/§6 一致：保底 eager 保证播放不被 spawn 失败影响）。

**O(1) 确定决策，无递归**
- 选槽 = 固定空闲位图 / 游标最低优先；`next_check`（§5.1/§5.2）= 简单算术；
  不做复杂遍历、不递归——"不知怎么分配"被消除（分配策略确定性：最低空闲槽）。

**复杂活踢后台**
- `join`、黑名单持久化、预留水位重算等重活不占 Master 事件循环（worker 收尾自报
  joined、重活交低优后台 / 宿主）。

**结果**
- Master 只剩「位图查槽 + 簿记读写 + 带超时 wait」，这些操作**结构上不可能失败**：
  分配失败 / spawn 失败 / 不知怎么分派等 panic 源被**设计移除**而非 try/catch 兜底。
- worker 批量爆炸时 Master 也只是"表满 → 拒任务"，绝不自己挂。
- 真 panic 仍视为 bug → 宿主 `kernel_ping` + 重建兜底（§5.2 层3），但概率被结构性
  压到极低。

---

## 6. 线程 init 与回收归 Master 管

> 与 §3.1 分界一致：**"是否建/收"由 Master 异步决策，"实际创建/join"由 Master 同步执行。**

- **init**：`kernel_init(cfg)` 同步建 Master 事件线程 + eager 保底 worker；hybrid
  扩容决策在 Master 事件线程内做，实际 `spawn` 失败不 panic（记日志、任务排队等
  空闲 worker），保底 eager 不受影响。worker **不自建**。
- **回收（worker 不自杀）**：Master 询问注册表 → 决定回收 → 通知该 worker
  `retiring`（worker 格标记 `retiring`）→ worker 完成当前实例收尾后**从线程函数返回**
  （而非自行 `exit`）→ Master `join` 该 worker 并回收其格。worker 永不自行终止，
  保证线程生命周期只有 Master 一个所有者。
- **线程内存**：每个 worker 栈/上下文生命周期归 Master 簿记；实例内存仍归各
  fmt/Decoder（allocator = c_allocator），实例即收即放（§4 lazy）。

### 6.1 任务提交面与句柄（草案）

宿主经 `submit(Task)` 投递任务，Master 受理后返回句柄，后续事件/取消都凭句柄：

```
Task { id: u64, kind: decode|transcode|metadata, format?: Format, source: Source }
Source = union { path: []const u8, memory: []const u8, store: SegStoreHandle }  // 草案
Handle = u64（Master 簿记表键：task_id → {state, worker_id, instance, event_seq}）
```

- 宿主 `submit(Task) → Handle`（非阻塞；超 cap 返回错误 `InstanceLimit`）。
- Master 完工 → 经 wait_event 推 `Event{ handle, kind: done|error, … }`；宿主
  `wait` 阻塞收事件（复刻现 wait_event 推模式）。
- 宿主可 `cancel(Handle)`（仅未开工/排队态）；已开工由 worker 经 `Reader.abort`
  中断（对齐 §13.1）。
- 短任务完工即领；长流任务句柄常驻（按流分配 + K 路分时，见 §3 图）。

### 6.2 worker 槽位表与任务重派（固定槽位 · 线程可换）

> 回答"线程卡死但主控完整时如何指派其他线程继续"：解码无 checkpoint，无法断点续跑，
> 因此**短任务 = 从头重跑；流式播放卡死 = 会话级故障**（切歌 / 重建，不重跑）。机制上
> 用**固定槽位表**承载，线程可替换（类线程池槽位），主控解绑坏 worker 后把任务
> **重新入队 / 指派预留槽位**。

**固定槽位表（slot 固定，线程可换）**

- 常驻 `slots[0..S]`（S = 池容量），槽位 = 任务执行位；**槽位与 OS 线程解耦**：
  - 槽位簿记 `{task_ref, instance, epoch}` 由 Master 写；
  - 线程挂在槽上执行（`slot_i ← thread_j`）；线程坏则**换线程不换槽**。
- 好处：任务重派只改 `slot.task_ref` 绑定，不搬解码状态；槽位容量即并发上限
  （对照 §5.1 派发决策读注册表统计 busy 槽）。

**registry ↔ slots 的一致性（换线程不换槽的交接）**

- 线程开工前：Master 先写 `slot.task_ref + epoch`，再写该线程 registry `busy`；
  worker 读到 `busy` 才动实例——槽与线程状态序一致，杜绝"槽已派新任务、旧线程仍
  在跑旧实例"。
- 线程收尾/被替换：worker 先写 registry `idle/retiring` 并**清自身 slot 引用**，
  再进 cv / 返回；Master 见 `idle` 才把该 slot 视为可再派或可回收。任一时刻
  "某 slot 有实例在跑" ⇔ "其线程 registry == busy"。

**卡死重派流程（Master 完整时）**

```
worker 停滞（last-activity 判定：now − last_activity > stall_timeout；§5.2 层2）
 ├─ 解绑 slot：清 task_ref，标 slot 故障
 ├─ 任务分流：
 │    ├─ 短任务（batch/metadata/decode）→ 重新入队 → 主控从预留池指派新线程重跑（从头）
 │    └─ 流式播放 → 会话级故障：收尾该流句柄 → 宿主收到 error/ended → 切歌/重建
 ├─ 旧线程处理：abort 唤醒可 join → join；否则 detach（§5.2 层2）
 └─ 补线程：从预留池取空闲线程挂到该 slot / hybrid spawn（§5.3 难度预留）
```

**"立刻强制回收 panic 线程"的现实化表述**

- 真 panic（段错误/abort）＝整进程崩溃，主控无"回收窗口" → 宿主重建（§5.2 层1/层3）；
- 进程内能"立刻回收"的 = **挂死（hang）线程**：标记退役 → abort 唤醒 → join；不可
  join 则 detach → 槽位换线程。不采用锁内信号级取消（UB，毁共享态）。

---

## 7. 同步直通 vs Async 主干的取舍

**决策（2026-09-08）：保留 sync 直通 + async 主干。**

| 路径 | 结构 | 用途 |
|---|---|---|
| **sync 直通** | 保留 `zk_decoder_open/read/seek_ms/position_ms/close`，调用线程同步驱动 1 实例 | 回归基线、单流稳定路径、调试 |
| **async 主干** | Master + Pool 提交面（新增 `zk_submit/…` 或等价 FFI） | 批量/128 路/异构任务并发 |

**代价与说明**：sync 直通等价"每路一次同步调用 = 一个独立解码会话"，与 FFmpeg
per-context 思路一致（**EraAudio 相对 FFmpeg 的对称**）；async 主干才能"单主控同时
执行不同任务"。二者共享 Module/Instance 层，不重复实现解码。

---

## 8. 文档间引用（更新或新建时核对）

- `docs/audio-kernel-zig.md` §8.4（三层模型/不变量）、§8.4.1（A/Sync 语义、
  调度规则）、§8.4.2（优先子项 ①–④）、§16.1（线程不变量——**待本设计落地时修订**）、
  §19 Phase G。
- `docs/engine-master-worker-scheduling.md`（调度语义说明，本文件取代其"线程模型"章；
  保留 §2.2/§2.3/§2.4 有效）。
- `docs/architecture.md` §9 引擎/线程现状（"1 会话 1 引擎线程"——本设计落地后更新
  为常驻内核描述）。
- `kernel/engine.zig` 头注释、`kernel/io.zig`（callback 形态）、`kernel/decoder.zig`
  （Decoder/Module 收敛点）、`app/core/audio-engine/build.zig`（静态库入口挂载点）。

---

## 9. 落地顺序（建议；尚未定稿）

1. 把 `decoder.open()` 的硬编码 switch 收敛为 `Module` 描述符表 + Registry 簿记
   （不改线程，纯结构；`zig build test` 全绿为准）。
2. 引入 `kernel_init/shutdown` 与 Master 事件线程（M=1 eager 播放保底），事件
   通道复刻 wait_event 推模式；旧 zk_* 直通保留对照。
3. hybrid：worker 状态注册表 + 空闲回收 + 动态新建（超时 wait 驱动）。
4. 接入 scanner 批量 tag（§8.4.2 ① metadata 快路径先行）验证 128 路。

> 每步均需 `zig build test`（ReleaseFast 全量）+ 引擎 ctest 无回归后进下一阶段。

---

## 10. 术语速查

| 术语 | 含义 |
|---|---|
| Master（主控） | 双能力：同步管线程生命周期（init/join/回收）+ 异步事件循环派发（§3.1） |
| Pool（调度池） | M 条 Sync worker（OS 线程）；短任务完成即领 / 长流按流分时 |
| Registry（模块注册表） | probe → Module → Instance；只读能力表 + 簿记/cap/护栏 |
| Module | 每格式只读能力表（fmt/*），进程内 1 份，实例共享 |
| Instance | `decoder.Decoder`（VTable+ctx），私有状态，每模块 0..N |
| worker 状态注册表 | `registry[i]` 每 worker 一格（线程键），worker 自写、Master 读；管线程状态/回收/空闲集合（§5） |
| worker 槽位表 | `slots[s]` 固定任务位（任务键），线程可换；管派发/重派；与 registry 分工见 §5/§6.2 |
| last-activity 停滞判定 | worker 推进时写槽位时间戳；`now − last_activity > stall_timeout` 判卡死（非完成时限，§5.2 层2） |
| Master 无失败定容簿记 | Master 定容预分配、运行期零堆分配、满即拒、O(1) 决策、重活踢后台——结构上不 panic（Linux 调度器式，§5.4） |
| 分工锚点 | 凡可能失败/panic/卡死的活交给 worker；Master 只做不会失败的最小簿记（§1/§5.4） |
| eager / lazy / hybrid | 常驻保底 / 按需即开即关 / 动态伸缩（Linux workqueue 式） |
| 完成即领（统一模型） | 完工先无锁 peek 一次：有排队即自领（省唤醒），无则进 cv 等派发/回收（§5.1） |
| sync 直通 | 保留 `zk_decoder_*`：调用线程同步驱动 1 实例（§7） |
| 表面同步内里异步 | 宿主 `submit`+阻塞 `wait` 封装成同步观感；内部 Master 编排 + 真并行（§3.1） |

---

> 本文件为设计定稿；动工前需同步修订 `docs/audio-kernel-zig.md` §16.1 与
> `kernel/engine.zig` 头注释（§2.1），并在 `docs/architecture.md` 落地后更新引擎
> 线程现状描述（§8）。
