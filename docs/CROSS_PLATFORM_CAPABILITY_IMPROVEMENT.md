# 跨平台通用内存管理与剪裁能力 —— 架构改进建议

> 目标：借鉴 Mineradio 的「进程工作集压缩 + 系统级内存 purge + 磁盘缓存 LRU + GPU 显存预算淘汰」
> 四层能力，把它们从 **Windows / JS / PowerShell 强绑定** 泛化为 **跨平台通用、多语言（可含 Kotlin）可移植**
> 的能力层。本文是**设计文档**，不包含具体改造代码。

---

## 0. 现状分析：哪些能直接复用，哪些被平台绑定死了

| 能力层 | 现状 | 平台绑定程度 |
|--------|------|--------------|
| L1 进程工作集压缩（`EmptyWorkingSet`） | `desktop/app-memory.js` / `system-memory.js` | 🔴 仅 Windows（psapi.dll / kernel32.dll / PowerShell） |
| L2 系统级 purge（`NtSetSystemInformation`） | `desktop/system-memory.js` | 🔴 仅 Windows，还依赖管理员/UAC |
| L3 磁盘缓存上限 + LRU + 可迁移目录 | `desktop/main.js` | 🟢 基本通用（仅路径/大小写归一化有平台差异） |
| L4 GPU/显存预算 + LRU + 原子换档 | `public/js/modules/02-visual/*` | 🟡 逻辑通用，但实现绑定 WebGL/JS |
| 自动化调度（interval/threshold/前台保护） | `main.js` `runMemoryAutoTick` | 🟢 纯策略，完全通用 |
| 能力检测 / 失败回退 / 度量 | 分散在 JS | 🟡 有总比没有好，但缺统一抽象层 |

**核心结论**：真正「跨平台难做」的只有 **L1 + L2**（OS 底层内存语义），其余（L3、L4、调度、策略）
本身已经是跨平台逻辑。所以跨平台改造的重点不是重写 UI，而是**把 L1/L2 抽成一个可插拔的
「原生平台适配器(native capability adapter)」**。

---

## 1. 总体架构：能力分三层，跨平台 = 只在最底层换实现

```
┌─────────────────────────────────────────────────────────┐
│  UI / 渲染层 (WebGL · Compose · 原生 · 任选，平台各自)    │
│  - L4 GPU 预算池 / L3 磁盘缓存 UI / 手动按钮 / 状态展示    │
└──────────────▲──────────────────────────────────────────┘
               │ 统一 IPC / 接口契约
┌──────────────┴──────────────────────────────────────────┐
│  核心逻辑层 (Kotlin MP 共享 · 或原 JS 核心)               │
│  - 调度: interval/threshold/前台保护/在途互斥/去抖        │
│  - 策略: 上传优先级、LRU 淘汰、原子换档、协作分帧          │
│  - 契约接口: MemorySnapshot / PurgeResult / CacheBudget   │
└──────────────▲──────────────────────────────────────────┘
               │ capability probe + adapter 抽象
┌──────────────┴──────────────────────────────────────────┐
│  原生适配层 (每平台一个实现)                              │
│  Windows:  EmptyWorkingSet + NtSetSystemInformation       │
│  macOS:    madvise(MADV_FREE) / task purgeable / killall  │
│  Linux:    madvise / malloc_trim / cgroup / zram          │
│  Android:  ActivityManager / WebView AIArchive            │
│  iOS:      os_proc_available_memory / darwin 语义         │
└──────────────────────────────────────────────────────────┘
```

关键设计：**UI 可以各平台各写；核心逻辑用共享语言（Kotlin MP）写一份；只有最底层的「OS 原生释放
原语」按平台各实现一个 adapter。** 这正是 Mineradio 缺、而 KMP 天然擅长的一层。

---

## 2. 能力抽象：先定义「契约接口」（跨语言、跨平台）

无论用什么语言实现，都先钉死这组类型。它们必须是 **OCaml/JSON/POD 风格的可序列化数据**，
便于出现在 FFI、IPC、进程边界上：

```kotlin
// 内存快照 —— 各平台都能量产的部分
data class MemorySnapshot(
  val totalBytes: Long,
  val usedBytes: Long,
  val usedPercent: Int,
  val processRssBytes: Long,
  val processHeapBytes: Long,
  val source: String,        // 平台来源: GlobalMemoryStatusEx / /proc/meminfo / tasking ...
)

// Purge 能力 —— 平台差异都藏在这里，契约对外保持统一
enum class PurgeTarget { WorkingSet, FileCache, ModifiedList, StandbyList, StandbyLow, Anonymous }

data class PurgeResult(
  val ok: Boolean,
  val freedBytes: Long,      // 可度量的核心字段
  val needAdmin: Boolean,
  val partial: Boolean,
  val perStep: List<StepResult>
)

// 磁盘缓存 / GPU 预算 —— 完全平台无关，纯业务契约
data class OwnershipBudget(val maxBytes: Long?, val maxRows: Int?, val itemBytes: Long?)
```

> 反模式规避：不要把 `PurgeTarget` 设计成 Windows 专用枚举名（如 `NtSetSystemInformation` 的 cmd）。
> 上面用的是**语义化目标**，平台 adapter 负责把语义翻译成各自的系统调用。

---

## 3. 平台适配层：把 Windows 能力翻译成「各平台的等价原语」

这是跨平台成功与否的分水岭。**不是所有平台都能 1:1 复刻 Mem Reduct**，所以要定义
「语义等价 + 能力回退」：

| 语义目标 | Windows 实现 | macOS | Linux | Android/iOS |
|---------|-------------|-------|-------|-------------|
| 压缩自身工作集 | `EmptyWorkingSet` | `madvise(MADV_FREE)` / 无直接等价 | `malloc_trim` / `madvise(MADV_DONTNEED)` | `WebView` 内部、无系统级 |
| 清系统文件缓存 | `FlushSystemFileCache` | `sync` + 无直接 purge（SIP 限制） | `echo 3 > /proc/sys/vm/drop_caches`（需 root） | 不可用 |
| 清待机/修改页列表 | `NtSetSystemInformation` | 无（有内核 `purgeable` 内存但不公开） | 待机页由内核管理，`drop_caches` 部分等价 | 不可用 |
| 提权触发 | UAC | `osascript`/`AuthorizationServices` | `sudo` / `pkexec` | 不可用 |

**必须坚持的规则**：
1. **能力探测先行**：启动时跑 `CapabilityProbe`，如实报告每平台支持哪些 target（`systemPurgeAvailable` 语义）。
2. **语义降级**：某平台没有「清待机页」时，UI 把该选项隐藏/置灰，而不是报错。
3. **度量闭环不能丢**：`freedBytes` 在 macOS/Linux 上可能拿不到精确值，就退回「已触发 + 前后 RSS 对比」，
   并标注 `source` 与估算误差,绝不能假装精确。
4. **权限边界：默认不开提权**，与 Mineradio 的「前台不弹 UAC / 自动释放默认锁」纪律一致。

---

## 4. 哪些该用 Kotlin 写、哪些不该

「允许使用 Kotlin 等其他语言」不等于「全用 Kotlin」。按职责切分收益最大：

**✅ 适合 Kotlin Multiplatform 共享的（平台无关 + 需要跨平台一致）：**
- L3 磁盘缓存容量上限 + LRU 淘汰算法（纯数据逻辑）
- L4 显存预算池的**决策逻辑**（字节预算、行数上限、LRU 挑选淘汰行、原子换档判定）
- 自动调度策略（interval / threshold / 前台保护 / 在途互斥 / 去抖）——现在散在 `runMemoryAutoTick`
- 契约接口、`PurgeTarget`、`MemorySnapshot`、能力探测结果的公共 schema

**🟨 适合各平台 native 实现的（强 OS 绑定）：**
- L1/L2 的原生释放原语（`EmptyWorkingSet` / `madvise` / `drop_caches` ...），用各平台的
  `expect/actual` 或 `platform.posix` / JNI / FFI 实现
- 提权触发（UAC / sudo / pkexec / AuthorizationServices）

**❌ 不必强行用 Kotlin 的：**
- WebGL / GPU 渲染与预算池执行（若保留现有视觉层，继续用 JS/现有 runtime 最省风险）
- 真正的渲染主循环

> 原则：**「讲预算、做淘汰、定策略」的代码尽量共享（Kotlin MP）；「真正触碰 OS/GPU 原语」的代码
> 尽量按平台隔离。** 这才能让「一套内存管理逻辑」在 Windows/macOS/Linux/Android/iOS 行为一致。

---

## 5. 把「前台保护」和「阈值门控」固化成通用策略模块

Mineradio 做得对且必须跨平台保留的三条策略，应抽成与平台无关的公共模块（借 Kotlin 写一份）：

1. **前台可见保护**：可见/聚焦/未暂停播放时,任何激进释放一律跳过（`foreground-visible` 语义）。
2. **阈值 + 间隔门控**：系统占用低于阈值不跑；距上次执行不足冷却窗口不跑；并发在途互斥。
3. **默认保守**：自动系统释放 / 提权默认关闭，仅在用户显式开启后生效。

这些现在散在 `main.js` 的 `memoryAutoState` / `runMemoryAutoTick` 里，跨平台重写时应整体搬进
共享核心，让三端行为一致、且 UI 只需对接同一套配置 schema。

---

## 6. 迁移顺序建议（降低风险）

1. **先抽契约 + 纯逻辑**：把 L3/L4 的预算/淘汰/调度抽成语言无关或 KMP 共享模块，先用 JS 侧双跑对比结果。
2. **再抽原生适配层**：把 L1/L2 收口成一个 `MemoryCapabilityAdapter` 接口，Windows 用现有实现，
   macOS/Linux 各加一个 adapter。UI 层只依赖接口，不再碰 `process.platform` / PowerShell。
3. **最后逐平台补能力 + 度量**：先做「能常态跑、不夸大 freedBytes」的通用版，再逐平台补强。

---

## 7. 一句话总结

跨平台 + 允许 Kotlin 的关键不是「把所有代码重写成 Kotlin」，而是：
**把与 OS 强绑定的 L1/L2 收口成一个可插拔的原生适配层（契约 + 语义 target + 能力探测 + 降级），
把平台无关的 L3/L4 预算/淘汰/调度策略放进共享核心（Kotlin MP 最合适），UI 各平台各写。**
这样既得到跨平台一致的内存管理与剪裁能力，又不牺牲每平台的原生极限 —— Mineradio 的前台保护、
阈值门控、默认保守、结果度量这几条纪律，则原样保留并做成平台无关的公共策略。
