# 交接提示词：修复 F1（纯事件 hybrid 回收）——在新会话直接粘贴本文件即可开工

> 用法：把本文件内容粘贴给新 opencode 会话（建议同时附上一句「先 git log --oneline -5 与
> git status 确认在 0424f7eb 附近、工作区干净/只有预期改动」）。本文件自包含：无需回看旧会话。

---

## 角色与目标
你是 Zig 内核并发工程师。任务：为 ArchoeraMusic 的常驻内核 runtime 实现**健壮的纯事件
worker 回收（hybrid 回落）**，根除此前三次原型未收敛的两类症状（A：大量 `worker spawn
failed` 日志的 churn；B：偶发整池挂起），并新增严格压测。**不要 git commit**。

## 仓库状态（开工前确认）
- 仓库根：`/home/betastudio2/文档/SPlayer-Next/ArchoeraMusic`
- 主干提交线（应处于 0424f7eb 附近）：
  - 3b504086 kernel seam 两刀基线；cc1343fd 接入 A 段（默认开启+A3 回退）；
    174283c6 B-2 停滞检测+定时兜底；c0ba3c90 B-3 槽恢复+max_streams；
    0424f7eb B 收口（F1 标开放）。
- `git status` 应干净（或仅无关 Flutter/README 外部改动——勿动）。

## 目标文件
- `app/core/audio-engine/kernel/runtime.zig` —— 唯一实现目标。
- 可读参考：同目录 `tables.zig`（WorkerTable：entries 的 state/class/…、
  WState、beginIdle/beginBusy/markBusy/beginRetiring、isReclaimCandidate）、
  `kernel.zig`、`khost.zig`、`task.zig`（waitEventTimeout 已保证，Clock.awake）。
- 设计稿（已按教训更新，重点读 §5.1/§5.2/§5.5 与 §9 未完工 #5）：
  `docs/engine-master-pool-design.md`。

## 现状（B-2/B-3 之后的 runtime.zig 事实）
- 线程模型：Master 事件线程 + 同质 worker 自取 Job 队列（完成即领，run-to-completion）。
- 锁/簿记：
  - `self.mutex`：队列 queue_head/tail、`inflight`、`reg` 写、`started_ns`/`stalled`/槽复位写。
  - `master_mutex`：`need_worker`、`shutdown_requested`、协调；`master_cv`。
  - 每槽原子数组（容量=cfg.max_workers，init 定容）：`started_ns: []atomic u64`（开工单调 ns，
    0=空闲）、`exited: []atomic bool`（worker 返回前最后一次触碰）、`stalled: []bool`（停滞
    detach 槽；shutdown 跳过其 join）。
  - `stall_count`、`master_event`（带超时兜底 latch，仅 Master wait/reset）。
- 增长：submit 里 `inflight > workers.items.len && len<max` → `need_worker`；Master 循环补建。
  `appendWorker` 现：先复用 `stalled[id] && exited[id]` 槽（`respawnInto`，绝不 join，旧线程
  已 detach）否则追加；`respawnInto` 复位槽再 spawn，失败回滚仍退役。
- worker 停滞分支：被 Master detach 的 worker 自返（stop 标志任务）只销毁节点+置 exited 即退。
- `scanStalled`（Master 定时兜底路径，stall_timeout_ns>0 时）：busy 超时 → stalled+detach+
  放弃 inflight；`respawnRetired` 每 tick 恢复一个自返停滞槽。
- `busyCount()`：持 mutex 数服役 busy worker（排除 stalled/exited）。
- Master 主循环：stall_timeout_ns==0 时纯事件（等 master_cv）；>0 时带超时等 master_event，
  超时到点做 scanStalled+respawnRetired。
- **当前没有**：`inflight_peak`、`need_reclaim`、`retire[]`、worker 正常退役/回收逻辑、`alive` 计数。

## 目标设计（照做并自行查缺；此前两处教训已内联）
1. **inflight_peak**（self.mutex 内维护）：submit 时 `if inflight>peak: peak=inflight`。
2. **排空事件 → 回收**：worker 完工把 `inflight` 减到 0 时（持锁判定），解锁后置
   `need_reclaim`（master_mutex）并唤醒 Master。这是唯一回收触发（正确性不依赖定时器）。
3. **Master maybeReclaim()**：仅当 `inflight==0` 时读 peak 并清零（新波次开始）；
   `target=max(min_workers, min(peak, max_workers))`；若可用 worker > target，对高 id 的
   **空闲**（reg state==idle、非 stalled/exited/已在 retire）置 `retire[id]=true`（self.mutex
   内判写）；随后 broadcast jobs_avail 唤醒被标记者收尾。
4. **worker 退役路径**：空闲且 (shutdown || retire[id]) 才考虑退出；**退出前在同锁内二次确认
   队列仍空**（期间来了任务就留下服役）。决定退出：置 reg beginRetiring/beginIdle、`exited=true`
   （最后触碰），再请求 Master（便于复用/再次评估）。不自建不自杀——这是执行 Master 的命令。
5. **防 churn 规则（本次新增、最关键）**：worker 被 retire 标记后若因新队列转去 **busy**，
   应**清掉自己的 retire[id]**（重新变得有用）；Master 只在下个排空事件重新评估。否则每波中途
   退出→再扩容=churn 复现。
6. **复用（整合两类）**：`appendWorker`/`respawn*` 统一处理：
   - `stalled[id] && exited[id]`：旧线程已 detach → **绝不 join**，直接覆写句柄；
   - `retire[id] && exited[id]`（正常退役）：旧线程已返回 → **锁外 join** 后覆写句柄
     （**绝不持锁 join**——死锁根因）；
   - 复位 retire/stalled/exited/reg/started，新 worker 进场即见复位态。
7. **可用 worker 计数**：growth/回收的「现役数」不能用 `workers.items.len`（该表从不收缩，
   含退役/停滞槽）。引入/维护 `active`（或等价「可服役数」），退役与复用精确 +1/-1，且
   submit 增长、maybeReclaim 都在同一把 master_mutex 语义下读取一致值。若与现有 stalled
   簿记冲突，以最小改动整合，保持 B-2/B-3 行为（stall off 时不变）。
8. **零丢任务**：任何时刻提交任务要么被服役 worker 执行、要么可触发扩容到有人接；禁止
   「alive 变 0 但队列有任务且无人能扩容」的挂起；退出前二次确认防丢。
9. **churn/挂起消灭**：验收压测中 `worker spawn failed` 计数必须 ≈0（spawn 真失败才允许
   出现，且不得风暴）；如出现，用 gdb 定位根因（下面有配方）。

## 验收（全过才可交付）
1. `cd app/core/audio-engine && zig build test` 绿（kernel 现 627 + 你的新增）。
   若报 `'oscl_base_macros.h' not found`：`rm -rf .zig-cache` 后重跑；**绝不中断正在跑的构建**
   （反复中断会污染共享 C 缓存——这是本仓库已知坑）。
2. 直跑多 seed：`BIN=$(ls -t .zig-cache/o/*/archoera-kernel-tests | head -1); for s in 1 2 3 4 5; do "$BIN" --cache-dir=./.zig-cache --seed=$s; done`
3. 新增测试（runtime.zig）：
   a) shrink：min=1,max=8，submit 1000 微小任务 → waitIdle → 池回落到 ≤min_floor（有界轮询）；
   b) 100×500 同尺寸波：worker 有界 ≤max、无 spawn-failed 风暴、计数精确；
   c) lazy min_workers=0：排空后回落 0；之后新 submit 可再扩容、无死锁；
   d) **400 波大(每波 1000) + 每 5 波追加 8 小**（曾复现 churn/挂起的确切模式）：快速终止、
      计数精确、spawn-failed≈0；
   e) 全程 已执行 == 已提交。
4. seam 回归：`zig build -Doptimize=ReleaseFast --prefix ./zig-out && cmake --build build &&
   ctest --test-dir build` → 13/13（含 test_engine_pool 的 max_streams 行、test_pool_pipeline
   的 A/B 与 FFmpeg 回退相）。

## 排查配方（若症状复现）
- 观察：压测二进制里 grep `worker spawn failed` 计数与耗时。
- 线程栈：`gdb -batch -ex "set pagination off" -ex run -ex "thread apply all bt 10" --args ./bin`
  配 `timeout -s INT`（ptrace_scope=1，只能以子进程方式跑 gdb）。若挂起：SIGINT 后看
  masterMain/workerMain/scanStalled/maybeReclaim/requestReclaim/appendWorker 等帧，判断
  死锁（谁持哪把锁等谁）。

## 约束
- Zig 0.16 `std.Io`（Mutex/Condition 在 Io 命名空间；*Uncancelable 变体）；io 用
  `std.Io.Threaded.global_single_threaded.io()`；timed wait 用 `task.waitEventTimeout`/Clock.awake。
- 绝不持锁 join；绝不对 detach 线程 join；生产路径无忙等（测试断言可有界轮询）。
- 默认（stall_timeout_ns==0、无退役场景）行为必须与现状字节一致；保留 kernel.zig/khost/session
  使用的导出 API（只加 cfg 字段/方法/私有函数）。
- 不要修改其它内核文件、pipeline/player/segstore/decoder；不要改 C seam 语义。

## 返回内容（精炼报告）
改动字段/函数清单；churn/挂起的**根因与修复**；retire-reset 与退出二次确认实现；新测试名；
验证输出（含 spawn-failed 计数与 400 波压测时长、多 seed 结果）。**不要 git commit。**

## 后续（本任务之外，供参考勿做）
- B 其余开放：#9 ring 直推 / worker 亲和 / waiting 停滞标记（播放接线面）；C=Benchmark
  （decode-optimization.md：先 perf 定位再优化）；Windows/MSVC 最后验证（CI）。
