# 引擎主控 + 调度池设计（完整 Zig 内核）

> 状态：**设计定稿（2026-09-08）· 未实现**；2026-09-09 按代码实况与 Zig 0.16 stdlib
> 核对后定点修订（§1 / §2.1 / §3 / §4 / §5.1 / §5.2 / §5.4 / §5.5 / §6.1–6.3 /
> §7 / §9 / §10），修订均带「2026-09-09」标注。2026-09-09 用户定：播放迁池
> （§6.3 流式会话）+ 池同质（保底 = min_floor 数量下限，无专属保底线程）。
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
- **主控（Master）＝大师型单点**（不是"纯异步事件循环"，修订 2026-09-09：能力归
  **Master async 事件线程独占**）：
  - **线程生命周期**：`kernel_init` 引导阶段按 **cfg.eager** 决定是否同步建 Master
    事件线程与 `min_floor` 个同质 worker（bootstrap；否则**按需就绪**——首个并发任务
    到达才补建，见 §3 启动预算）；此后**创建与正常退出全部由 Master async 事件循环执行**——
    扩容就地 `spawn`，回收走「worker 自报已返回 → Master reap-join（非阻塞）」，
    停机 join 全部可 join 线程。**线程生命周期只有一个执行者 = Master async**。
  - **任务派发**：同一事件线程做 **submit 受理 → Registry 查能力/簿记 → 分派 →
    簿记（cap/护栏）→ 完工处理 → 伸缩决策**（probe 不在 Master 路径，见分工锚点）。
  - 分界：**创建/收线程的决策与执行都发生在 Master 事件循环内**；唯一例外是
    `kernel_shutdown` 终止期可阻塞 join（事件线程已无服务对象）；见 §3.1。
  - Master 自身**不做解码**。
- **分工锚点（全文可记忆的一句话；修订 2026-09-09：spawn 移出 worker 脏活）**：
  **凡可能失败 / panic / 卡死的活交给 worker（解码 / probe+实例 open / 缓冲分配）；
  Master 只做不会失败的最小簿记（位图查槽 / registry 读写 / 带超时 wait）**。
  **spawn 不在此列**：执行归 Master async 独占（§3.1 能力 A），其失败（`SpawnError`）
  在 Master 事件循环内作**非致命**处理（记日志 + 任务排队），见 §5.4。脏活崩了换
  worker；Master 会崩的唯一理由是内核 bug → 宿主重建。
- **调度池（Pool）**：M 条 Sync worker（OS 线程，全 Zig `std.Thread`，**同质可互换**），
  分到任务后在线程内**同步逐帧解码**（单流帧级串行，天然正确）。
- **模块注册表（Registry）**：只读 Module 能力表（fmt/* 每格式 1 份）+ 实例簿记
  （计数 / cap / fd·内存护栏）。**probe + 实例 open 在 worker 侧执行**（脏活），
  Registry 只提供查表与登记，不在 Master 路径上做任何文件 IO。
- **init 三态（eager / lazy / hybrid，Linux workqueue 式思路；修订 2026-09-09：
  eager = 数量下限，非专属线程）**：
  - **eager**：线程数下限 `min_floor` 常驻 + 预建模块（覆盖单流播放等"必在"路径；
    下限是**数量保证**，池 worker 同质，无专属保底线程，见 §2.1/§4）；
  - **lazy**：短任务（批量 tag / metadata）按需开实例、即收即放；
  - **hybrid**：worker 池随负载**动态伸缩**——由 Master 容量调节器定容（§5.5）。
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
> `kernel_shutdown` 统一 join（`join 全部可 join 线程`；§5.2 层2 曾 detach 者凭共享
> shutdown 标志自退，不 join，见 §5.2 修订）。`fmt/*` 模块与 `Decoder` 仍保持**纯
> Sync 语义**（无内部线程、无 async 状态机），由 Pool worker（async 主干）或 **sync
> 直通调用线程**（§7）驱动。**保底 = 池 worker 数量下限 min_floor**，池同质可互换、
> 无专属保底线程（修订 2026-09-09）。

保留的（**不修订**）：
- 模块**全局只读**、实例**私有可变**（§8.4 不变量 1）——128 路互不污染的根基；
- 单流内**不做帧级并行**（§8.4.1）——MP3 Huffman/FLAC 预测/Opus 状态依赖串行；
- **零拷贝边界**（§8.4 不变量 3）：Sync-Direct 单线程内才可能零拷贝；跨线程移交
  packet 必须拷贝。

确立的（修订 2026-09-09）——**任务切换只发生在「完全空闲」边界（run-to-completion）**：
- **worker↔任务绑定是运行至完成**：worker 一旦接到任务（registry `busy`）就独占跑到
  done / error / abort，**无抢占、无时间片、无中途换任务**（生产环境不允许暂停一个
  正在解码的实例去做别的；实例私有状态也经不起中间人切换）。"并行"的唯一单位是
  **OS 线程**，一个任务在其 worker 上不吃不喝跑到底——池内不存在"超线程/时间片式
  多任务叠跑"。
- **热切换 = 只在该 worker 完全空闲（无绑定任务）的派发点发生**：worker 完工 →
  置 `idle` → peek/等派发；此时它才"热"可接新任务（完成即领，§5.1）。换任务的
  安全窗口**只有这一个**。
- **推论**：`retiring`/回收、停机的生效点也都在 worker 空闲边界（先完成任务收尾再
  返回，§5.2/§6）；pinned 流式会话在"等 host 消费/暂停"（`waiting=true`）时**并非
  空闲**——仍绑定同一会话，绝不被改派其它任务。
- 卡死重派不靠中途切换：靠 **abort + 从头重跑 / 会话级故障**（§6.2），无断点续跑。

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
│   │ 职责：受理 submit → 簿记(cap/护栏) → 查 Registry 派发；     │
│   │      收完工/可回收事件；§5.5 容量调节 + 伸缩决策            │
│   │（probe / open / 解码全在 worker——Master 不做可阻塞 IO）    │
│   │                                                            │
│   ├── Registry（只读 Module 能力表 + Instance 簿记）           │
│   │      Module：fmt/* 只读能力表（进程内每格式 1 份）          │
│   │      Instance：worker 侧 decoder.open 后登记（0..N）        │
│   │                                                            │
│   │  Worker 状态注册表 registry[worker_id]（§5，含 class）     │
│   │                                                            │
│  Pool（M 条 Sync worker；M 由 cfg + §5.5 调节；同质可互换）      │
│    ├─ 短任务：完成即领（向 Master 报完工 → 领下一件）            │
│    └─ 长流/播放：pinned 会话 1 worker : 1 流（§6.3），          │
│       PCM 经 ring 直推宿主，不经 Master 逐帧                    │
└──────────────────────────────────────────────────────────────┘
```

- 启动：`kernel_init(cfg)` 建 Registry + 定容表；**线程按 cfg.eager 同步建或按需懒拉起**
  （Master 事件线程 + `min_floor` 个同质 worker，见 §3 启动预算）。
- 退出：`kernel_shutdown()`：Master 停收新任务 → 置共享 shutdown 标志 → 通知 worker →
  join 全部**可 join** 线程（曾 detach 的 worker 凭标志自退，不 join）→ 释放模块表/注册表。
- 通道：Master ↔ 宿主 事件 **复刻现有 wait_event 推模式**（condvar/ring）；
  Master ↔ worker 用内部 condvar / 空闲栈 / 原子，一次最小握手（不做零同步）。
- Zig 0.16 原语（修订 2026-09-09；必要时对照 `/usr/lib/zig/std`）：
  - `Mutex`/`Condition` 已从 `std.Thread` 迁至 **`std.Io`**（`std.Io.Mutex` /
    `std.Io.Condition`）。Master 带超时等待 = **`std.Io.Event.waitTimeout`** + `set/reset`
    （§5.1「零轮询」的直接实现）；worker 阻塞 = `std.Io.Condition.wait`（0.16 为
    `Cancelable!void`——可取消，shutdown / 回收 / `Reader.abort` 的唤醒路径据此落地）。
  - 线程 = `std.Thread.spawn(SpawnConfig, …)` → `SpawnError`（ThreadQuotaExceeded /
    OutOfMemory / …）＝ §5.4「spawn 失败不 panic、任务排队」的语言级支撑；
    `SpawnConfig.stack_size` **必须显式设**（m4a Debug 曾有约 60MB 栈帧史，勿信默认值）。
   - **worker 每线程持有自己的 `std.Io.Threaded` 实例**；`kernel/io.zig` 的 `Reader.io`
     需参数化，不能继续依赖 `global_single_threaded`（文件位置读 pread 跨线程安全，
     但 Condition/Event 等待是 per-Io 的）。

**启动与首帧延迟预算（修订 2026-09-09：加 Master+线程后启动仍须快于 FFmpeg）**

- **度量口径（用户定，修订 2026-09-09）**：
  - **冷启动（headline）**：从**下发指令到第一帧 PCM 出现**的 wall，FFmpeg 与自研同口径
    （`--player-file` 起动 / 会话 open → 首个可听帧）。仅比冷启动；不得拿"池已热"充数。
  - **热启动（第二条指标，亦可赢）**：池就绪后 `open_stream`→首帧 wall。FFmpeg **无热池**，
    每次请求都是"开新会话"（probe+init）——这正是与我们热路径的**可比口径**：我们热路径
    多付**查表 + 任务分发**（µs 级固定开销），FFmpeg 付 `probesize=1MB + analyzeduration=0.5s`
    + 每会话完整上下文 → **热路径目标：仍快于 FFmpeg 每次会话冷开**（播放器切歌等
    复用场景，逐次兑现）。
- **按操作分级启动（不做"统一 kernel_init 就绪"）**：用户操作分三档，启动成本随档位走，
  Master/Pool 线程**不被无条件拉起**：
  - **版本/帮助等纯 CLI**（`--version`/`--help`）：**不碰 kernel、不建线程**——内核是静态库，
    Zig 版本常量导出即用（现 `kernel.kernel.zig` `version_string`），零启动成本；
  - **tag 拆分 / 批量元数据 / 单发 decode**：只须 Registry + 惰性 worker——**首任务到达才
    spawn**（min_floor=0 起，首个 submit 触发补建），Master 簿记先行即可；
  - **播放 / 需立刻并发**：首个 `open_stream` 到达时补建到 min_floor（播放路径保证
    新会话即刻拿 worker，§5.5）。
  - 意义：`kernel_init` 从"启动即建 Master+worker"变为**按需就绪**；代价只在真正要
    并发的那一步付。
- **冷启动预算分解（都在"指令→首帧"这一个墙钟内）**：
  - 纯 CLI：进程起动 → 输出，无 kernel；
  - 需要线程的档位：`kernel_init` 就绪（Registry + 定容表 + Master/`min_floor` worker，
    个位数 ms）→ 首个 `open_stream`/submit → 空闲 worker **就地 probe+open → 首块 PCM**，
    一次最小握手，无多余队列往返；
  - **压 FFmpeg 的锚**：以上整段 wall 须**严格小于** FFmpeg 同文件冷启动
    （`probesize=1MB / analyzeduration=0.5s` 基线，audio-kernel-zig.md §16/§17.3 口径）
    到首帧的 wall。Master 只加一次 O(1) 簿记 + 一次事件唤醒的固定开销。
- **`kernel_init` 自身（触发时）**：定容表预分配（S = max_streams + max_cap_elastic，
  几十~几百 KB 级）+ spawn Master 与 `min_floor` worker。**不读任何文件、不预建解码器
  实例**；Zig comptime 使 fmt/* 能力表零加载成本 → "eager 预建模块"只指能力表已就位，
  不是 open 实例/预读文件。
- **验收**（§9 每步门禁）：ReleaseFast 下测**冷启动指令→首帧 wall**（headline，与 FFmpeg
  同文件同口径）须**快于 FFmpeg**；**热启动 open_stream→首帧 wall** 亦须快于 FFmpeg
  每次会话冷开（第二条指标）；`--version` 零内核成本与 `kernel_init` 就绪子项作分解明细；
  数值随 decode-optimization.md §6 同口径（perf / 同机 i9）落表。

### 3.1 Master 双能力：异步线程生命周期 × 异步任务派发

> 澄清（2026-09-08 用户定，修订 2026-09-09）：Master 不是"纯异步事件循环"，但**线程
> 生命周期与任务派发都归 Master 的 async 侧（事件线程）独占执行**——决策与执行都在
> 事件循环内。「bootstrap 阶段（kernel_init）同步建线程」与「运行期由 Master async
> 建/收线程」的分界见能力 A。
> 术语修订（2026-09-09，弃 await）：内核**不使用 async/await/协程/绿线程**——并发 =
> 阻塞 OS 线程 + 事件/状态驱动（`std.Io` condvar/signal + 原子读格）。文中「async/
> 事件循环」一律指 **Master 事件线程的事件驱动编排**，不是语言级 async；解码恒 Sync。

**能力 A —— Master 异步执行线程生命周期（创建与正常退出）**

> 修订（2026-09-09）：**线程创建与正常退出由 Master 事件线程（async）独占执行**——
> 这是硬性要求，不是可选项。旧稿「spawn 可由低优后台执行」「join 踢出事件线程」取消
> （§3.1/§5.2 层3/§5.4 已同步修订）；线程生命周期不存在第二个执行者。

- 线程生命周期**唯一所有者 = Master 事件线程**（async 侧）。`kernel_init` 引导阶段
  按 **cfg.eager** 同步建 Master 事件线程与 `min_floor` 个同质 worker（bootstrap，
  先于事件循环启动）；`cfg.eager=false`（纯 CLI/批量单发/--version 场景）则 Master/
  worker **首任务懒拉起**（§3 启动预算，启动不付线程开销）；
  此后运行期的**新建与正常退出全部在 Master 事件循环内执行**，不委托低优后台、不交
  宿主。
- hybrid 扩容：**决策 + 实际 `spawn` 都就地发生在 Master 事件线程内**（§5.4 无失败
  路径）——spawn 失败不 panic（§5.4），仅记日志、任务继续排队等空闲 worker；`min_floor`
  下限保证新会话/新任务不被 spawn 失败影响。
- 正常退出：Master 事件线程发 `retiring` → worker 收尾返回 → **worker 先自报「已返回」
  （事件推送）** → Master 事件线程据此 `join`（对**已返回**线程的 reap，非阻塞）。
  join 的"不阻塞"由「先自报、后 reap」协议保证：事件线程**永不去 join 一个尚未退出
  的线程**。
- `kernel_shutdown` 为终止性动作：事件线程停收 → 置共享 shutdown 标志 → 通知 worker →
  join 全部**可 join** 线程（终止期可阻塞 join：事件线程已无服务对象）；detach 者凭
  标志自退（§5.2 层2 修订）。
- 归 Master 管：worker **不自建、不自杀**（不自杀 = 不自行 `exit`；正常退出由 Master
  事件线程驱动后 worker 收尾返回）。

**能力 B —— 异步 · 任务派发与伸缩决策**
- Master 事件线程运行期**等待事件**（submit / worker 完工 / worker 可回收 / 超时），
  事件到来才处理：受理任务 → 查 Registry 能力/簿记 → 派发 → 簿记 cap → 决定是否
  扩容/回收。
- 空闲时**不忙等**（condvar/ring 阻塞），不占解码线程。

**分界（为何可共存）**
- "**要不要**建线程/收线程" = 异步决策，在 Master 事件循环里做；
- "**去执行**创建 / 正常退出（reap-join）" = 也由 Master 事件线程在事件循环内
  就地执行——创建就地 spawn；正常退出走「worker 自报已返回 → Master reap」，
  对未退出线程**永不 join**，因此不违背「Master 事件线程永不阻塞」（§5.2 层3）。
- 因此"主控 Async"与"线程生命周期归主控"**统一为同一侧**：决策与执行都在 Master
  事件循环内；不与「解码恒 Sync」矛盾——生命周期归 Master，逐帧解码归 worker。

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
| **eager** | 数量下限常驻 | 单流播放必在、模块表预载 | 池容量恒 ≥ `min_floor`（非专属线程）；模块表进程内 1 份 |
| **lazy** | 按需开、即收即放 | 短任务（批量 tag/metadata/decode 单发） | 实例"开→解析→关"，Master 只登记不缓存 |
| **hybrid** | 动态伸缩（Linux workqueue 式） | 批量/128 路高峰 vs 低谷 | Master 容量调节器定容（§5.5）：盈余跨收水位即收、赤字跨建水位即建；总容量 ≥ min_floor 恒成立 |

> 修订（2026-09-09）：hybrid 不再用"负载高新建 / 长闲回收"的朴素表述，改由
> **§5.5 目标容量调节器**量化界定"建多少 / 收多少"——回收和创建的数量与时机由 Master
> 每次事件唤醒/临界区即时裁决，超时退居兜底。eager/lazy/hybrid 三种 init 状态**可
> 同时并存**（播放长流 + 弹性批任务），因此统计先按 `class: pinned | elastic` 分开
> （§5.5 混杂 init 节），长短任务互不污染伸缩决策。

**播放路径覆盖**（修订 2026-09-09：**播放迁池**）：播放 = **长流会话**（§6.3），
作为 pinned 任务挂在池上，**1 流 : 1 pinned worker**（§5.5 class）。`min_floor` 保证
新会话总能拿到 worker（等价现有 C 壳"1 会话 1 引擎线程"的替代——但它是**数量下限**
不是专属线程：pinned 流占走 worker 时，批量弹性的 deficit 自动补建，二者互不挤兑）。
**sync 直通（zk_*）退为回归基线 / 单流调试路径**（§7），不再是生产播放通道。

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
  `reclaimable: bool`、`task_ref?`（长流任务句柄）、
  `class: pinned | elastic`（修订 2026-09-09：允许混杂 init 后必须按任务类统计，
  见 §5.5——pinned = 当前挂着长流/stream 任务；elastic = 短任务或空闲，参与伸缩）、
  `waiting: bool`（pinned 会话在合法消费等待/暂停中置位；停滞判定须排除，§5.2 层2）。
- 写：worker 每进入空闲/开工/将收尾更新自己的格子（单写者，无锁 / 原子足够）；
  **worker 自提交**「我已空闲 idle_since 起 / 我可回收」。
- 读：Master 事件循环**每次被事件唤醒或带超时 wait 到点**时**询问**注册表，
  聚合出 idle/busy/retiring 计数 + 最老空闲 id（§5.5 调节器输入，原子读 O(1)）。
- 语义：**回收不统一进行**（不做"全部空闲后一起收"）；回收由 **§5.5 容量调节器**按
  「盈余数量」逐个指定（从最老空闲起）→ 发 `retire` → worker 收尾 → join。
  "长时间空闲"不再是唯一判据，褪为调节器的兜底上限（§5.1 修订）。

**为何不做"全部线程无任务后统一回收"**：统一回收把"线程数"当整体开关，无法表达
"数量下限常驻 + 弹性伸缩"；每 worker 自提交 + Master 询问能精确表达 eager/lazy/hybrid
的混合需求（总数恒 ≥ min_floor 的保底语义 + 批量高峰外的空闲 elastic worker 逐个回收）。

---

### 5.1 状态同步与唤醒协议（谁等谁、何时醒；Async↔Sync 互通）

> 注册表只回答「**对方现在是什么状态**」（决策时读一次）；它不回答「**什么时候变了、
> 该叫醒谁**」。唤醒与有界等待由本节的**事件通道 + 两处有界等待**协议补齐。

**双通道（状态与事件分离）**

| 通道 | 内容 | 写 | 读 | 语义 |
|---|---|---|---|---|
| **状态格** registry[i] | state / idle_since / task_ref / reclaimable / class / waiting | 该 worker 独占写（无锁/原子） | Master 只读聚合 | "现在是什么"——决策依据 |
| **事件通道**（condvar / 信号） | 完工 / 我空闲了 / 可回收 / 派发 / retiring | 任一方 | 另一方 | "发生了什么、该叫醒谁"——唤醒依据 |

- Master **不主动盯格**：worker 完工/空闲时发事件把它叫醒，Master 醒后才读格决策。

**两处有界等待（谁也不永久等）**

- **worker 空闲**：阻塞在自己的 `cv` 等 Master 消息（派发 / retiring / shutdown）；
  **不自设超时、不轮询、不自杀**。不会永久等——Master 对它必有动作（派活 / 回收 /
  停机），由 Master 保证。
- **Master 空闲**：阻塞在 `master_cv` 等事件（宿主提交 / worker 完工 / shutdown），
  **带超时 = 距「最早可回收点」的时刻**。超时醒 → 询问注册表 → **跑一次 §5.5 调节器**
  （无其它事件时仍收敛到目标容量）→ 回到阻塞。
  - 实现现状（2026-09-09）：当前 Master 循环为**纯事件**——只等 `master_cv`，**不设超时**；
    `std.Io.Event.waitTimeout` 能力已由 `kernel/task.zig` 保证但**热路径/当前 Master 未用**
    （无 timed wait、无轮询）。「最早可回收点」定时兜底待回收专项落地时接。

**Async 回收触发如何界定（非周期 tick）**

- 回收触发点不是固定周期，而是 Master 单点算出
  `next_check = min(idle_since + idle_timeout)`，只睡到那一刻；
- 到点回收一次，然后回到带超时阻塞。**零轮询**：这是"下个事件必然发生的时刻"
  的带超时等待，不是周期扫描，不拖慢内核。
- 修订（2026-09-09）：本段只是**最底层兜底**。回收/创建的正确性、时效与数量由
  **§5.5 调节器**随每次事件唤醒 + §5.1 临界区即时裁决保证——worker 完工/空闲时
  Master 被唤醒的次数越多，收敛机会越多；`next_check` 超时只在「一切静默（无事件、
  无完工）」时保证仍收敛到目标。回收不再「依赖超时才触发」。

**不回收正在运行的线程**

- **state 先行更新**：worker 开工前先把格置 `busy` 再执行；空闲前先把格置
  `idle + idle_since` 再进 cv。Master 只把 `state == idle` 的 **elastic** worker 放入
  §5.5 回收候选（surplus 判据）；`busy` 与 `pinned` 永不进候选（`idle_timeout`
  仅作调节器兜底上限，见 §5.1/§5.5 修订）。
- **回收单一所有者 = Master**：只有 Master 读格 + 发 retiring，无"两个回收者抢同一
  worker"竞态。

**零轮询汇总**

- worker 空闲 = condvar 真睡眠（CPU 0）；Master 空闲 = 带超时 condvar 真睡眠；
  状态 = 无锁/原子共享内存只读一次，不忙等。
- **等待原则（用户定 2026-09-09）**：主控↔线程的关系是**状态驱动**——Master 只需
  "读状态（registry 格）+ 信号唤醒"，热路径**尽量避免 timed wait / await**（无事件即
  真睡眠，事件到才醒）。timed wait 仅作为**低频兜底**（停机看门狗、§5.1 next_check），
  且该能力**已被保证**：`kernel/task.zig` `waitEventTimeout`（`Io.Event.waitTimeout` +
  `Clock.awake` = CLOCK_MONOTONIC），测试覆盖"set 前 → true / 永未 set → false"。

**派发：无指定线程，Master 自主决策（并依赖 Async 启动）**

- worker 完工 → 写格 `idle` → 发「空闲」事件；
- Master 收到事件 → 若有排队任务，**选任意空闲 worker**（空闲集合线索 =
  registry 中 idle 的 id / 槽位表空闲位，见 §6.2 一致性）→ 写格 `busy + task_ref`
  → signal 该 worker cv → worker 醒去执行；
- 若 submit 时无空闲 worker：**hybrid 决策**——Master 读 registry 统计 busy 数 vs
  队列深；未达 max M 且积压 → Master 在事件循环内**同步 spawn** 新 worker
  （worker 不自建）；新 worker 入 idle 格，Master 再把排队任务派给它。
- （"建多少 / 何时建"统一由 **§5.5 调节器**按 `deficit` 提前建，供应领先需求；本处只是
  其中一种触发路径——派发语义不变。）
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

- 隐患：worker 置 `idle` 后先 peek（A 模型）可能正想自领，Master 却在临界区判其
  可回收（§5.5 surplus）欲发 retiring——两者对同一 worker 冲突。
- 消解：**peek 自领与 idle 置位之间用同一把短锁/原子段**（Master 读 idle 判回收也走
  同一临界区）。worker 在临界区内决定"自领 or 进 cv"；Master 在临界区内决定
  "再派 or retiring"。二者互斥，结果唯一：worker 要么拿到任务、要么进 cv 等被派、
  要么收到 retiring 收尾——不会出现"worker 自领了任务又被回收"。
- 保底下限（修订 2026-09-09）：同质池无专属保底线程——**回收永不让「池线程总数」
  低于 min_floor**（§5.5）；低于下限时空闲 elastic worker 一律不进入 retiring 候选。

---

### 5.2 故障模型：崩溃 / 卡死 / 主控失联

> 补 §5.1 的隐含假设：worker 置 `busy` 后**未必能完工并回报**——任务可能故意
> 崩溃（panic）或死锁/卡死。分三层，且**「Master 事件线程永不阻塞」是首要设计约束**。

**层 1 · 崩溃（panic）——正解是"不让 panic 发生"，不是"回收线程"**

- Zig panic 默认 **abort 整进程**，进程内无法安全恢复单线程（可能正持锁 / 写共享态）；
  因此不做"panic 线程回收"。
- **解码路径零 panic**：一切畸形 / 截断 / 恶意输入走 **error 返回**，绝不 `panic` /
  `unreachable`。任务结果带 `error` 回报 Master → Master 正常回收 worker、上报宿主。
  "故意搞崩溃的任务"在正确实现下 = 一个 error 任务，不是线程事故。
  > 修订（2026-09-09）：「现状 fmt 已遵循 error set 纪律」**不成立**——fmt/* 与
  > decoder.zig 曾有 44 处 `unreachable` + 3 处 `@panic` 引用（多数应为 switch 穷举
  > 兜底，行为无害，但需逐处审计确认）。作为**落地前置**：§9 ①（switch → Registry
  > 收敛）的验收清单加入「panic/unreachable 逐处审计 + 替换为 error 返回」，全绿后
  > 本条"零 panic"才作为不变量生效。
  > **审计结论（2026-09-09，§9 ① 随行）**：35 处生产 `unreachable`/`@panic` **全部可证
  > 安全**（穷举完备 / 控制流·分派门控，见审计记录），关键字清单 0 输入可达；另定位并修复
  > **2 处非关键字的输入可达 panic**：`fmt/als/core.zig` `ra_flag` 保留值 3 →
  > `@enumFromInt` panic（改 error.Corrupt，恶意 m4a ALS 轨可达）、`zkRead` 位深护栏
  > （convert 仅接受 8/16/24/32/64，违约位深在 FFI 面拦下，防未来 codec 契约外位深
  > 触达 `pcm/convert` else 分支）。剩余可证安全项保留但入 fuzz 回归清单。
- **FATAL 逃生舱（用户定 2026-09-09）**：遇到**不可预知 / 无法按正常错误归类处理**的
  文件时，允许任务以 **FATAL error 直接收尾**——语义是**会话级错误上报**（宿主收到
  `Event{ kind: fatal }` → 跳过该文件 / 重建会话），**不是进程 abort**；且**不做 FFmpeg
  无限回退**（未接管/可分类错误走现有回退；FATAL 意味着"别重试"）。它与"error 纪律"
  的关系：解码路径仍零 panic（层1），FATAL 只是错误归类体系的**最粗一级**（兜住
  预想不到的情形），进程存活、Master 正常回收 worker。
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
  - 修订（2026-09-09）：停滞判定**只适用于"应当持续推进却没推进"**。pinned 播放/
    长流会话的"无推进"常是**合法的消费等待**——host 暂停、音频缓冲满暂缓拉帧、seek
    间隙。此类状态 worker 置 `waiting=true`（§5 字段），判死前显式排除；只在
    `waiting=false` 却停滞超时才按 §6.2 会话级故障处理。
  - 判死后：实例私有 → **放弃即泄漏该实例内存**（单次可接受），registry 格复位、
    新 worker 由 Master 就地 spawn 顶替（§5.5）；
  - 真死锁线程**不能 join（会永久 block Master）、也不能在锁内 cancel** →
    **detach**；代价是占一个 OS 线程（锁纪律保证不会普遍发生）。
  - 修订（2026-09-09，detach ↔ shutdown 一致性）：detach 后 Master 不再持有其句柄 →
    `kernel_shutdown` 的「join 全部」对它是**不可 join** 的。落地约定：
    1. 全局共享 **shutdown 原子标志**；worker 线程函数主循环每轮检查，detach 线程
       据此自行收尾返回（不 join）；
    2. `kernel_shutdown` = join 全部**可 join** 线程；detach 者留给宿主
       `kernel_shutdown_force`（进程/库退出）兜底；
    3. loss 账目：进程存活期间至多遗留（detach 次数）个 OS 线程——§9 验收基准里加
       「detach 后复用一个 OS 线程的压测计数」。

**层 3 · 主控失联 —— 不做"重启 Master"，做"重建整个常驻内核"**

- **首要防护：Master 事件线程永不阻塞**——**不 join 未退出的线程**：worker 收尾后
  先自报 joined，Master 只对**已返回**线程 reap（join 留在 Master 事件循环内执行，
  非阻塞；见 §3.1 能力 A 修订）；Master 不做解码、不做大分配、不 join 未退出线程；
  临界区只读格 + 短簿记。Master 自身低危、不自死锁。
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
| 死锁/长任务 | `now − last_activity > stall_timeout`（停滞，非 deadline；排除 waiting） | 放弃实例+detach worker+Master 按 §5.5 spawn 顶替 |
| Master 失联 | 宿主 `kernel_ping` 超时 | `kernel_shutdown_force`+`kernel_init` 整库重建 |

---

### 5.3 对抗性任务防御：黑名单 / 危险等级 + 难度预留替换

> 范围（修订 2026-09-09）：本节为 **post-MVP 预留**，排到 §9 phase 4 之后。首批只落
> §5.2 层1（error 纪律）+ 层3（宿主 ping 重建）即可；普通卡死由层2 last-activity
> 兜住已够。未定稿前本节不写入实现验收清单。

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

> **分工锚点（修订 2026-09-09：spawn 移出 worker 脏活）**：凡可能失败 / panic / 卡死的
> 活交给 worker（解码 / probe+实例 open / 缓冲分配）；Master 只做**不会失败的最小簿记**
> （位图查槽 / registry 读写 / 带超时 wait）。**spawn 执行归 Master async**（§3.1 能力 A），
> 其失败（`SpawnError`）在 Master 事件循环内作非致命处理（记日志 + 任务排队，见下）。
> worker 崩了 → 换 worker（§6.2）+ 任务重跑；Master 唯一会崩的理由是内核 bug →
> 宿主重建（§5.2 层3）。

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
  的非致命结果"（§3.1/§6 一致：min_floor 下限保证新任务不被 spawn 失败影响）。

**O(1) 确定决策，无递归**
- 选槽 = 固定空闲位图 / 游标最低优先；`next_check`（§5.1/§5.2）= 简单算术；
  不做复杂遍历、不递归——"不知怎么分配"被消除（分配策略确定性：最低空闲槽）。

**复杂活踢后台（修订 2026-09-09：join 不在其列）**
- **`join` 不入后台**：对已返回线程的 join 是近零阻塞的 reap，且**必须由 Master 事件
  线程执行**（§3.1 能力 A：创建与正常退出归 Master async 独占）。踢后台的只有离线
  重活——黑名单持久化、预留水位重算、跨会话指标聚合等（worker 收尾自报 joined 后，
  Master 顺手 reap，余下重活交低优后台 / 宿主）。

**结果**
- Master 只剩「位图查槽 + 簿记读写 + 带超时 wait」，这些操作**结构上不可能失败**：
  分配失败 / spawn 失败 / 不知怎么分派等 panic 源被**设计移除**而非 try/catch 兜底。
- worker 批量爆炸时 Master 也只是"表满 → 拒任务"，绝不自己挂。
- 真 panic 仍视为 bug → 宿主 `kernel_ping` + 重建兜底（§5.2 层3），但概率被结构性
  压到极低。

---

### 5.5 目标容量调节器：Master 界定线程回收与创建的数量

> 缘起（2026-09-09 用户）：纯事件+超时驱动有盲区——(a) worker 空闲后**只等 Master
> 带超时醒**才可能被收：若其他 worker 一直忙、Master 被频繁唤醒，具体某个空闲
> worker 仍可能滞留到 `idle_timeout` 才被收，空闲线程长期占着 OS 线程/栈；
> (b) 创建只在「无空闲且积压」时追需求，「建多少 / 收多少」没有量化依据。
> 解法：Master「学会」用一个**确定性 O(1) 目标容量调节器（controller）**界定数量——
> 正确性挂**每次事件唤醒 + §5.1 临界区即时裁决**，`next_check` 超时降为「一切静默
> 也会收敛」的兜底，回收/创建不再依赖/等待它。

**混杂 init 是根因（为什么必须按任务类分开统计）**

> 修订（2026-09-09 用户）："线程结束时间基本一致"只在**任务相对统一**时成立——一批
> 同类短任务（批量 tag / metadata / decode 单发）确实同时完工、同时空闲，完工事件
> **成片到达**，正是 Master-Async 最擅长的波形：自我唤醒、无需超时即可整批裁决。
> 真正的难点是**允许 eager / lazy / hybrid 混杂 init**：播放长流与弹性批任务在同一池
> 内交错。长流的结束由宿主任意驱动（暂停/切歌/seek/播完）、与其它任务**不同步**——
> 它的完工不是"容量信号"，只是释放一个 worker；把长短任务混进同一个 busy/idle 统计，
> 长流会一直占着 busy 却不可收，长流结束又伪装成"空闲波"。→ **先按任务类分统计，
> 再算容量**。

**输入（Master 每唤醒时 O(1) 聚合；全原子读 / 位图计数，§5.4 无失败）**
- registry 每格带 **`class`**（pinned / elastic，§5 修订）：回收候选**只从 elastic
  idle 取**；`pinned` 永不入候选（无论空闲与否）。
- registry 聚合：`pinned` 计数、`elastic_idle` / `elastic_busy` / `retiring` 计数、
  最老空闲的 `idle_since`；
- 队列深 `backlog_elastic`（短任务积压）；每类预估服务时间 `avg_service`（§5.3 同源）。

**目标容量（按类分开：elastic 走调节器，pinned 走宿主界定的并发流上限）**
```
elastic_busy = busy − pinned
C_elastic = clamp( elastic_busy + ceil(backlog_elastic / load_factor),
                   0,  max_cap_elastic )
surplus    = elastic_idle − spare        // spare = 预留安全垫（§5.3；首批可为 0）
deficit    = C_elastic − (elastic_idle + elastic_busy)
pinned     ≤ max_streams                 // 并发播放/长流上限（宿主逐路 open_stream）
total      = pinned + elastic_idle + elastic_busy ≥ min_floor   // 回收不跌破
```
- **总量定容（修订 2026-09-09，§5.4 对齐）**：`pinned + elastic ≤ S`，
  `S = max_streams + max_cap_elastic`——`kernel_init` 定容表 / 槽位表 / 护栏按 S 预分配
  （"表满即拒"返回 `InstanceLimit`，§5.4）。`max_streams` 由宿主并发播放承诺决定，
  `max_cap_elastic` 覆盖 128 路批量，二者在 cfg 里独立可调。
- **min_floor 是总量下限**（同质池，无专属保底线程）：播放会话优先吃 `elastic_idle`
  或按需 spawn（class 升 pinned）；空闲不足时 elastic deficit 自动补建。
- **class 随任务变**：elastic worker 被派成播放/长流 → 升 pinned（受 max_streams 约束）；
  流结束回落 elastic idle。pinned 完工只释放 worker，不当作 elastic 容量信号。

**决策（临界区 / 每唤醒即时执行，不带超时）**
- **创建**：`deficit > 建水位` 且未达 max_cap_elastic → Master 就地 spawn
  `min(deficit, 建步长)` 个 elastic。**提前建**（供应领先需求），不被动等积压追需求。
- **回收**：`surplus > 收水位` → 把**最老空闲的 elastic** `min(surplus, 收步长)` 个标
  `retiring`。弹性波次完工（done 成片到达）时在同临界区即时裁决、整批回落，不等
  超时——**统一任务同时结束恰是 Async 最擅长的情形**；混杂态下 pinned 长流继续跑，
  其 worker 不因 elastic 空闲被误收。
- **滞后死区**：`收水位 ≤ C_elastic ≤ 建水位` 区间内不动作，防「建一个收一个」抖振。
- 节奏：每事件轮至多建/收 `步长` 个，高并发下容量也不会大起大落。
- 常量：`load_factor` / `spare` / 双水位 / 步长 / `max_streams`：真机校准后以常量落库
  （§6.1 式）。

**触发不依赖单一超时（回答"不能完全依赖超时信号进 Async"）**
- 调节器挂在**每次事件唤醒**（submit / 完工 / 可回收）+ §5.1 短临界区：事件越多
  收敛机会越多；`next_check` 超时仅保证「无任何事件」时仍收敛到目标。
- 因此**回收/创建的正确性、时效、数量都不依赖超时**——超时只是最坏情形兜底。
  worker 被闲置多久、批量回收多少，由 Master 的容量模型决定，不由 tick 决定。

**与既有协议的关系（不推翻 §5.1，只升级裁决）**
- worker 仍自提交 idle + 先 peek 自领；临界区内 Master 裁决从「再派 or retiring(等
  超时)」扩为「再派 or 就地 retiring（surplus>阈值）or 进 cv（等派）」。
- 回收所有者仍只有 Master；worker 仍不自建、不自杀（§3.1 能力 A 不变）。

**首批落地（并入 §9 ③④）**：先带最简常数版调节器（min_floor / max_cap / 双水位 /
步长），`load_factor`、`spare` 用保守初值；真机基准后再替换常量。

---

## 6. 线程 init 与回收归 Master 管

> 与 §3.1 能力 A 一致（修订 2026-09-09）：**线程创建与正常退出由 Master 事件线程
> （async）独占执行**——决策在事件循环内；`spawn` 就地、`join` 只对**已返回**线程
> reap（先自报、后 reap，非阻塞）。旧稿「实际创建/join 由 Master 同步执行」的措辞
> 已作废——执行者也归 Master async 侧，无第二个执行者。

- **init**：`kernel_init(cfg)` 引导阶段按 **cfg.eager** 同步建 Master 事件线程 + `min_floor`
  个同质 worker（否则懒就绪，首任务才补建，§3 启动预算）；hybrid 扩容决策在 Master
  事件线程内做，实际 `spawn` 就地、失败不 panic（记日志、任务排队等空闲 worker），
  min_floor 下限不受影响。worker **不自建**。
- **回收（worker 不自杀）**：Master 事件线程询问注册表 → 决定回收 → 通知该 worker
  `retiring`（worker 格标记 `retiring`）→ worker 完成当前实例收尾后**从线程函数返回**
  （而非自行 `exit`）并**自报已返回** → Master 事件线程 `join`（reap）并回收其格。
  worker 永不自行终止，保证线程生命周期只有 Master async 一个所有者。
- **线程内存**：每个 worker 栈/上下文生命周期归 Master 簿记；实例内存仍归各
  fmt/Decoder（allocator = c_allocator），实例即收即放（§4 lazy）。

### 6.1 任务提交面与句柄（草案）

宿主经 `submit(Task)` 投递任务，Master 受理后返回句柄，后续事件/取消都凭句柄：

```
Task { id: u64, kind: decode|transcode|metadata|stream, format?: Format, source: Source }
Source = union { path: []const u8, memory: []const u8, store: SegStoreHandle }  // 草案
Handle = u64（Master 簿记表键：task_id → {state, worker_id, instance, event_seq}）
```

- 宿主 `submit(Task) → Handle`（非阻塞；超 cap 返回错误 `InstanceLimit`）。
- Master 完工 → 经 wait_event 推 `Event{ handle, kind: done|error|fatal, … }`；宿主
  `wait` 阻塞收事件（复刻现 wait_event 推模式）。`fatal`（§5.2 层1 FATAL 逃生舱）＝
  不可预知输入 → 会话级收尾：宿主跳过文件/重建，内核不 abort、不无限回退 FFmpeg。
- 宿主可 `cancel(Handle)`（仅未开工/排队态）；已开工由 worker 经 `Reader.abort`
  中断（对齐 §13.1）。
- 短任务（decode/transcode/metadata）完工即领；**`kind=stream`（播放/长流）＝会话**
  （修订 2026-09-09：播放迁池）：句柄常驻、pinned worker 1:1、PCM 经 ring 直推宿主
  （不经 Master 逐帧），seek/cancel/pause 凭句柄——语义见 §6.3。

### 6.2 worker 槽位表与任务重派（固定槽位 · 线程可换）

> 回答"线程卡死但主控完整时如何指派其他线程继续"：解码无 checkpoint，无法断点续跑，
> 因此**短任务 = 从头重跑；流式播放卡死 = 会话级故障**（切歌 / 重建，不重跑）。机制上
> 用**固定槽位表**承载，线程可替换（类线程池槽位），主控解绑坏 worker 后把任务
> **重新入队 / 由 §5.5 补建线程执行**。

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
worker 停滞（last-activity 判定：now − last_activity > stall_timeout；§5.2 层2，
 pinned 流须先排除 waiting/暂停静默，§5.2 层2 修订）
 ├─ 解绑 slot：清 task_ref，标 slot 故障
 ├─ 任务分流：
 │    ├─ 短任务（batch/metadata/decode）→ 重新入队 → Master 按 §5.5 deficit 指派/
 │    │   spawn 新线程重跑（从头）
 │    └─ 流式播放 → 会话级故障（§6.3）：收尾该流句柄 → 宿主收到 error/ended → 切歌/重建
 ├─ 旧线程处理：abort 唤醒可 join → join；否则 detach（§5.2 层2）
 └─ 补线程：Master 就地 spawn（§5.5）挂到该 slot（§5.3 预留池为 post-MVP 备选）
```

**"立刻强制回收 panic 线程"的现实化表述**

- 真 panic（段错误/abort）＝整进程崩溃，主控无"回收窗口" → 宿主重建（§5.2 层1/层3）；
- 进程内能"立刻回收"的 = **挂死（hang）线程**：标记退役 → abort 唤醒 → join；不可
  join 则 detach → 槽位换线程。不采用锁内信号级取消（UB，毁共享态）。

---

### 6.3 流式会话（播放迁池；修订 2026-09-09）

> 决定（用户）：生产播放 = 池内**长流会话**（pinned worker 1:1）；`zk_*` sync 直通
> 退为回归 / 调试路径（§7）。submit→done 事件模型服务不了实时播放，故补会话级流式路径。

- **生命周期**：宿主 `open_stream(source, fmt_hint?) → Handle` → Master 从 elastic idle
  取 worker（不足则按 §5.5 spawn，class 升 pinned）→ worker probe+open 实例 → 进入
  playing。存活期该 worker `class=pinned`、不入回收候选、不参与 elastic 伸缩。
- **帧通路（不绕 Master）**：worker 解码 → **宿主侧 ring buffer 直推**（C 壳管线消费，
  沿用现 wait_event 推/ring 语义）；Master 只在会话边界经手（open / seek / cancel /
  error / ended），**逐块不触发 Master 事件**——批量风暴不会给播放引入抖动。
- **控制**：seek / pause / resume / cancel 凭 Handle；已开工中断经 `Reader.abort()`
  （§5.2 层2 可断 IO）。`paused` / 缓冲满暂缓 置 `waiting=true`，停滞判定排除
  （§5.2 层2 修订）。
- **会话级故障**：pinned 流卡死 = 会话故障（§6.2）→ 收尾句柄 → 宿主收 error/ended →
  切歌/重建，不重跑解码。真退出（挂死）走 §5.2 层2 detach 路径。
- **容量归属**：pinned 计入 total（≤ S，§5.5），不计入 elastic；`max_streams` =
  宿主并发播放承诺，超限 `open_stream` 拒绝。会话结束 worker 回落 elastic idle
  （可被批量复用或按 surplus 回收，§5.5）。
- **首批节奏**：先支持 `max_streams = 1`（单播放会话）+ 并发批量，验证互不干扰后放开。
- **实时约束注意**：Master 事件线程设高调度优先级（§5.2 层3），保证会话边界控制
  （seek/cancel）不被批量簿记延迟；ring 生产/消费在 worker↔宿主直接完成，Master
  不在逐帧路径上。

---

## 7. 同步直通 vs Async 主干的取舍

**决策（2026-09-08；修订 2026-09-09：播放迁池后 sync 直通不再承担生产播放）**

| 路径 | 结构 | 用途 |
|---|---|---|
| **sync 直通** | 保留 `zk_decoder_open/read/seek_ms/position_ms/close`，调用线程同步驱动 1 实例 | 回归基线、单流调试、对照测试（**非生产播放通道**；播放走 §6.3 流式会话） |
| **async 主干** | Master + Pool 提交面（新增 `zk_submit / zk_open_stream / …` FFI） | 批量/128 路异构任务 + 流式播放会话（§6.3） |

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

> 未完工明细（2026-09-09 对照本节与 §5/§6/§7；2026-09-09 二次标注：✔核内路径已满足 /
> △ 已满足·接线面补齐 / ✖ 属接入或 Benchmark 留最后）：
> 1. ✔ §6.1 Task 完工层（done|error|fatal + Handle 槽映射）已由 kernel/task.zig + khost.zig
>    满足（generic run fn）；kind/source/format 的结构化 FFI 语义属 `zk_submit` 接线面（✖）。
> 2. △ §6.2 槽位/线程可换已随 B-3 落地一部分：停滞 detach 槽待旧线程自返后由 Master
>    复用/重派，池容量可恢复满编（§6.2/§5.2）。
> 3. △ §6.3 session 已落 + Host max_streams 硬计数（B-3）；ring 直推 / worker 亲和 /
>    waiting 停滞排除仍属播放接线面（✖）。
> 4. △ §5.1 定时兜底已落（stall_timeout_ns>0 时 Master 以 Io.Event.waitTimeout 睡到
>    next tick，纯事件为快路径；=0 保持原纯事件行为）。
> 5. ✖ §5.5 完整回收/调节器 deferred（§9④ hybrid，接线期；持锁 join 教训已记录）。
> 6. △ §5.2 停滞检测最小已落（B-2）+ 槽位容量恢复（B-3）；黑名单/难度预留仍未做。
> 5. ✖ §5.5 完整回收（F1 hybrid）仍开放——曾两次原型竞态未收敛（churn/偶发挂起），
>    列为需专注排障的独立工作。
> 7. ✖ §3 冷/热启动 wall 基准落表 vs FFmpeg（Benchmark 部分，另行）。
> 8. △ §7/§9③⑤/FFI：接入已开第一刀——`zk_engine_init/shutdown/decode_once` +
>    流式 `zk_engine_open/read/seek_ms/position_ms/close`（kernel_bridge.h，加法式，C 侧对照
>    测试 test_engine_pool == sync 逐样本）；播放迁池 S1（native_decoder 解码源换流式
>    seam，ARCHOERA_ERA_POOL 门控默认关，headless A/B == 逐位 + 失败语义对齐
>    sync==stream==decode_once）已落；scanner 128/tag 仍属后续接入；Windows/MSVC
>    链接验证归 Windows CI。

> 进度（2026-09-09）：接入 S1 已落——`zk_engine_*` seam（decode_once + 流式会话）加
>   kernel_bridge.h；C 壳 `native_decoder.c` 解码源可在 `ARCHOERA_ERA_POOL` 下切到流式
>   seam（headless A/B 逐位一致 + 失败语义 sync==stream==once==decode_once；SegStore 会话
>   排除）；**A1 默认开启已本地评估**（默认 pool-on 与 ARCHOERA_ERA_POOL=0 全 ctest 绿）；
>   **A3 FFmpeg 回退端到端**：pool-on 下 .mov(PCM) Zig 不接管 → 回退 FFmpeg 成功且未走池；
>   A2 scanner/zk_metadata 仍未做；本文件 §9①-②/内部能力/加固均已绿。
> 进度（2026-09-09）：① 完成（registry.zig + decoder 表驱动 + panic 审计，622 测试全绿）；
> ②/内部打磨（均不接生产线）完成：runtime.zig（Master 停机/懒就绪协调 + 同质 worker +
> 完成即领 + 大 batch 排空）、**worker 状态注册表接入 runtime**（每 worker 开工 busy/完工
> idle 单写自格，Master `summarize` 读状态；畸形输入池内 error 不 panic）、runtime 弹性扩容
> （§5.5 骨架：backlog 压 worker 时 Master 补建至 max_workers，cap 界住；低负载不扩）、
> 接缝加固（停机后 submit 拒绝 / convert 契约外位深 ReleaseFast 不 panic / cfg 校验 /
> zkRead 溢出·超大分配安全 / 截断扫描 fuzz-lite 并发喂池只 error 不 panic /
> 停机·提交并发竞争不 panic 不悬挂 / registry 未登记·未来标签安全 UnsupportedFormat /
> 128 路混合格式并发解码实例隔离零 panic（§9⑤ 前哨内部等价））、tables.zig
> 回收（§5.5）实验：事件驱动「波次峰值保留」可行但多波次竞态未稳 → 留接线期专项落地
> （Master join 须在锁外：曾定位持锁 join 旧线程死锁根因，记录在案）
> 流式会话能力落地 kernel/session.zig（§6.3 池内形态：长流分块串行解码 + seek +
> 会话故障 error/fatal，分块==一次性验证；worker 亲和/ring 属接线面）
> 常驻内核 Host 落地 kernel/khost.zig（§3 宿主入口面：init/submit(Handle,
> cap InstanceLimit 满即拒)/完工事件/shutdown；关键路径零分配；仍不接 C 壳）
> （WorkerTable/SlotTable）、task.zig（done|error|fatal + wait + 保证的 timed wait
> `waitEventTimeout`，Clock.awake）、Reader.io 参数化、zkRead 位深护栏。② 余项（接线时补）=
> wait_event 推 + 每线程独立 Io 语义。

1. 把 `decoder.open()` 的硬编码 switch 收敛为 `Module` 描述符表 + Registry 簿记
   （不改线程，纯结构；`zig build test` 全绿为准）——**验收含 panic 审计**：fmt/*
   逐处 `unreachable`/`@panic` 替换为 error 返回（§5.2 层1 修订；现 44+3 处）。
2. 引入 `kernel_init/shutdown` 与 Master 事件线程 + Pool（播放档 `cfg.eager=true`、
   min_floor=1，同质 worker；批量/单发档懒就绪，见 §3 启动预算），
   事件通道复刻 wait_event 推模式；旧 zk_* 直通保留对照。——**落地即定**：worker/Master
   各持自己的 `std.Io.Threaded`、`Reader.io` 参数化、`SpawnConfig.stack_size` 显式设
   （§3 原语修订）；shutdown 置共享标志、join 可 join 者（§5.2 层2 修订）。
3. **单播放会话迁池**（§6.3，`max_streams=1`）：`open_stream` 会话 + pinned 记账 +
   ring 直推 + `waiting` 停滞排除——替换 C 壳"1 会话 1 引擎线程"播放路径，sync 直通
   转回归对照。
4. hybrid：**§5.5 目标容量调节器**（elastic 伸缩 + min_floor 总量下限 + 双水位 +
   步长 + 滞后死区；定容 S = max_streams + max_cap_elastic）+ worker 状态注册表 +
   空闲回收 + 动态新建（= §5.1 短临界区；每事件唤醒即时裁决，超时兜底）。
5. 接入 scanner 批量 tag（§8.4.2 ① metadata 快路径先行）验证 128 路；随后做
   **播放 + 批量混杂压测**（pinned 不被批量干扰、批量风暴不引入播放抖动）。
   （§5.3 黑名单 / 危险等级 / 难度预留为 post-MVP，移出本批目标。）

> 每步均需 `zig build test`（ReleaseFast 全量）+ 引擎 ctest 无回归后进下一阶段。
> **启动门禁（2026-09-09，§3 启动预算）**：每引入线程的一步（②③）加测**冷启动指令→首帧
> wall**（headline）与**热启动 open_stream→首帧 wall**——两者均须快于 FFmpeg 对应口径
> （冷：同文件冷启动；热：FFmpeg 每次会话冷开）；`kernel_init` 就绪时间作分解明细。

---

## 10. 术语速查

| 术语 | 含义 |
|---|---|
| Master（主控） | 大师型单点：线程生命周期与任务派发均由 **Master async 事件线程独占执行**——创建（bootstrap 除外）与正常退出（先自报后 reap-join）在事件循环内；停机 join 可 join 者（§3.1） |
| 目标容量调节器 | Master 界定**线程回收与创建的数量**：先按 `class: pinned|elastic` 分统计（混杂 init 长短任务不互相污染），再对 elastic 算 `C_elastic` 目标容量 + 双水位滞后 + 步长；每事件唤醒/临界区即时裁决，超时仅兜底（§5.5） |
| Pool（调度池） | M 条 Sync worker（OS 线程，**同质可互换**）；短任务完成即领 / 长流播放 pinned 会话 1:1（§6.3） |
| Registry（模块注册表） | 只读 Module 能力表 + 实例簿记（cap/护栏）；probe+open 在 worker 侧（§1/§5.4） |
| 流式会话 | 播放/长流的池内形态：pinned worker 1:1、ring 直推宿主、seek/cancel 凭句柄、max_streams 上限（§6.3） |
| Module | 每格式只读能力表（fmt/*），进程内 1 份，实例共享 |
| Instance | `decoder.Decoder`（VTable+ctx），私有状态，每模块 0..N |
| worker 状态注册表 | `registry[i]` 每 worker 一格（线程键），worker 自写、Master 读；管线程状态/回收/空闲集合（§5） |
| worker 槽位表 | `slots[s]` 固定任务位（任务键），线程可换；管派发/重派；与 registry 分工见 §5/§6.2 |
| last-activity 停滞判定 | worker 推进时写槽位时间戳；`now − last_activity > stall_timeout` 判卡死（非完成时限，§5.2 层2） |
| Master 无失败定容簿记 | Master 定容预分配、运行期零堆分配、满即拒、O(1) 决策、重活踢后台——结构上不 panic（Linux 调度器式，§5.4） |
| 分工锚点 | 凡可能失败/panic/卡死的活交给 worker（解码/probe+open/缓冲分配）；Master 只做不会失败的最小簿记；spawn 执行归 Master、失败为非致命（§1/§5.4） |
| eager / lazy / hybrid | 数量下限常驻 / 实例即开即关 / 动态伸缩（§5.5 调节器定容；同质池，eager = min_floor 非专属线程） |
| min_floor / max_streams / max_cap_elastic | 池线程总数下限 / 播放长流并发上限（宿主承诺）/ 弹性批量上限；`min_floor ≤ total ≤ S`，`S = max_streams + max_cap_elastic`（§5.5） |
| 完成即领（统一模型） | 完工先无锁 peek 一次：有排队即自领（省唤醒），无则进 cv 等派发/回收（§5.1） |
| 热切换 / 完全空闲边界 | worker↔任务绑定运行至完成（无抢占/时间片/中途换任务）；换任务唯一安全窗口 = worker 完全空闲的派发点（§2.1） |
| sync 直通 | 保留 `zk_decoder_*`：调用线程同步驱动 1 实例（§7） |
| 表面同步内里异步 | 宿主 `submit`+阻塞 `wait` 封装成同步观感；内部 Master 编排 + 真并行（§3.1） |

---

> 本文件为设计定稿；动工前需同步修订 `docs/audio-kernel-zig.md` §16.1 与
> `kernel/engine.zig` 头注释（§2.1），并在 `docs/architecture.md` 落地后更新引擎
> 线程现状描述（§8）。
