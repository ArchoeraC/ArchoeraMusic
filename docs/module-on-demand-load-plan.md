# 模块按需加载规划（Module On-Demand Loading）

> 状态：**规划中（2026-08-15 立项，未实施）**
> 定位：为自研 FFI 模块建立统一的「按需加载 + 依赖 preload + 使用完释放」生命周期
> 管理，避免把全部原生模块一次性载入内存；需要什么、加载什么，用后归还。

---

## 1. 背景与目标

### 1.1 目标（用户要求，2026-08-15）
1. **模块按需加载**：不是应用启动就一次性把所有原生库 dlopen 进内存；
2. **依赖可 preload**：模块启动前，其依赖先就绪（如 scanner 依赖 libe_sqlite3）；
3. **使用完即释放**：模块生命周期结束归还资源（内存），不常驻无效模块。

### 1.2 为什么现在做
各模块加载点分散且无统一生命周期：
- 有的惰性单例（scraper / subsonic），有的构造即载（scanner / downloader），
- sqlite 启动即预加载（共享实例契约，必须常驻），
- **没有任何释放机制**——库句柄一旦打开永不归还。

---

## 2. 现状盘点（2026-08-15 实测）

| 模块 | 加载时机 | 依赖 | 释放现状 |
|---|---|---|---|
| sqlite（libe_sqlite3） | `main()` 最早处 `preloadBundledSqlite`（RTLD_GLOBAL\|DEEPBIND） | — | **常驻**（dart sqlite3 与 scanner-ffi 共享同一实例，进程生命周期内不可卸载） |
| scanner（scanner-ffi.so） | `LibraryScanner` 构造时 load（`library_store` 每次 scan 新建）+ 子 isolate 内再 load | sqlite（ad-hoc preload） | 无；`dispose` 只关进度回调，库句柄保留 |
| scraper（libarchoera_scraper） | `ScraperBindings.instance` 惰性单例 | — | 无 |
| subsonic（libarchoera_subsonic） | `SubsonicBindings.instance` 惰性单例 | transcoder（Go 侧 dlopen） | 无 |
| downloader（libarchoera_downloader） | `DownloaderEngine.init()`（下载页打开时） | — | Rust 侧 `destroy` 释放堆，库句柄保留 |
| mediaEngine / fft | `AudioEngineProcess.start()` 每次会话 **spawn 独立进程** | ffmpeg（vcpkg，进程内） | **进程退出即归还** ✅（已有进程级隔离范式） |
| transcoder（libarchoera_transcoder） | Go 侧 dlopen / Dart 注入绝对路径 | — | Go 运行时管理 |

> 结论：**「一次性加载所有程序」现状并不存在**（启动仅预载 sqlite），主要缺口是
> ① 统一生命周期管理（注册表/引用计数）② 依赖关系显式化与 preload ③ 真正的释放语义。

---

## 3. 关键技术约束：dart:ffi 无法 unload

`dart:ffi` 的 `DynamicLibrary` **没有 close/unload API**（设计限制，公开接口只有
`open / process / executable`）。因此：
- 用 `DynamicLibrary.open` 加载的库，Dart 侧无法 dlclose；
- FFI `lookupFunction` 返回的**函数指针在 dlclose 后悬垂**（再调用即崩溃）；
- 绕开方案都不干净：经 libc 手动 `dlopen/dlclose` 拿不到 Dart 打开的内部句柄，
  且双开句柄的引用计数无法正确归零。

由此确立**两档释放策略**（见 §4.3）：模块自身资源销毁（安全基线）与
子进程隔离（真正归还内存，audio-engine 已示范）。

---

## 4. 目标架构

### 4.1 统一模块注册表 `NativeModuleRegistry`
在既有 `NativeLibPaths`（路径解析，不动）之上新增一层生命周期管理：

- 每个模块声明：`NativeModule`（复用枚举）+ `dependencies`（依赖图）+ 释放回调；
- `acquire(module)`：DFS 先确保依赖 loaded → dlopen → 引用计数 +1 → 返回句柄；
- `release(module)`：引用计数 -1 → 归零时执行该模块 dispose 回调 + 句柄失效；
- 保留模块常驻标记（sqlite = 进程常驻，不参与计数/释放）。

### 4.2 依赖 preload（模块启动前就绪）
依赖图（显式化现有隐式依赖）：
```
scanner    → sqlite   （必须 RTLD_GLOBAL，且常驻）
subsonic   → transcoder（Go 侧 dlopen，注册表只保证路径注入）
mediaEngine→ fft / ffmpeg（进程内，audio-engine 产物同目录）
```
`acquire(scanner)` 自动先 `ensureLoaded(sqlite)`；**只 preload 被依赖项，绝不一次性全载**。

### 4.3 释放策略（两档）
- **Tier 1（默认 · 安全）**：调用模块自带销毁（`scanner_free` / `downloader_destroy` /
  `scraper_destroy` / subsonic 销毁）归还 native 堆内存；Dart 侧绑定位空、GC 回收；
  库句柄保留（dart:ffi 限制，.so 代码段常驻——各模块均很小，可接受）。
- **Tier 2（激进 · 可选）**：重量级模块（scanner 的 C# runtime、downloader 的 Rust）
  改造为**子进程隔离**（对齐 `AudioEngineProcess` spawn/stop 范式），「释放」= 终止
  子进程，真实归还全部内存。进度事件经 stdout/管道或 IPC 回传。

### 4.4 与既有机制的关系
- `preloadBundledSqlite`（RTLD_GLOBAL\|DEEPBIND）：保留为 sqlite 常驻加载的唯一入口；
- `NativeLibPaths`：纯路径解析，注册表复用；
- scanner 子 isolate 内二次 load：改走注册表 acquire（同进程共享句柄，引用计数 +1）。

---

## 5. 分阶段落地

### 阶段① 注册表 + 按需加载 + 依赖 preload + 引用计数
- 新增 `lib/services/native_module_registry.dart`：acquire/release/常驻标记/依赖图；
- 将 6 处加载点（scanner/scraper/subsonic/downloader/engine/fft）改为经注册表
  acquire，行为不变（惰性时机保持现状）；
- scanner 加载前依赖 sqlite 的显式化 preload（复用现有逻辑）。

### 阶段② Tier 1 释放接入

#### ②.0 释放时机与互斥总表（2026-08-15 逐模块核实）

| 模块 | native destroy 能力（实测） | Dart 绑定形态 | 释放时机（接入点） | 互斥条件 | 遗留问题 |
|---|---|---|---|---|---|
| scanner | **无**（C# NativeAOT 仅导出 `scanner_scan/cancel/free`，**无模块级 destroy**；`scanner_free` 只释放扫描结果内存） | `LibraryScanner`（主 isolate 持句柄）+ 每次 scan 在子 isolate 内**二次 load**（isolate 退出即回收） | `LibraryNotifier.startScan` 的 `finally`（完成/失败/取消后）——现有代码已在此 `dispose()`，只关回调；补「句柄失效 + 引用计数归零」 | `_scanning` 防重入；release 在 `await scanner.scan` 返回后 | 无 native destroy 可调 → Tier 1 仅「绑定位空 + NativeCallable.close」；真实内存归还只能 Tier 2 子进程化 |
| downloader | **有**：`DownloaderEngine.dispose()` 已调 Rust `destroy`（释放堆 + 断点落盘） | `DownloadController`（**非 autoDispose**）持 `DownloaderEngine`；`bootstrap.dart:46` `ref.read(downloadControllerProvider)` → **启动即常驻，违反按需** | **当前仅 `_teardown`（ProviderContainer 销毁时）**；需新增「空闲 suspend / 进入下载页 resume」 | `activeCount==0`（无 queued/resolving/running）+ `_gen` 丢弃异步 init 竞态 | **最大改动点**：bootstrap 强制常驻 + 全局 provider 无法按页销毁 → 需「惰性 init + 活跃会话计数」 |
| scraper | **有**：`ScraperController.dispose()` → `archoera_scraper_destroy(handle)` ✅ | `ScraperBindings.instance` 惰性单例（库句柄常驻，接受）+ 每会话一个 `ScraperController` | `ScrapeController._cleanup()`（done/error/empty/run 失败）——**已完善**；仅剩注册表引用计数接入 | `state.scraping` 单会话；start 前先 `_scraper?.dispose()` 清残留 | 无 |
| subsonic | **有**：`SubsonicController.dispose()` → `archoera_subsonic_destroy(handle)` ✅ | `SubsonicBindings.instance` 惰性单例；**Dart 侧当前无任何创建点**（Controller/Admin 定义了但未接入 UI） | 无会话可释放；唯一运行时路径 `goShredFiles`（handle=0，Go 全局单例，一次性销毁操作） | — | 按需已天然满足，阶段②无需接入点；`SubsonicAdmin` 接入 UI 后另行评估 |
| mediaEngine | **进程退出即归还** ✅（spawn/stop 范式） | `AudioEngineProcess` | stop → 进程退出 | 播放会话 | 无 |
| fft | **有**：`FftAnalyzer.dispose()` → `fft_destroy` ✅ | **每次播放会话新建 `FftAnalyzer`**（无句柄缓存），`PcmAnalyzer` 持用，`AudioEngineProcess._pcm` 生命周期绑定会话 | `AudioEngineProcess.stop` 时 `_pcm.dispose()`（native handle 归还）；库句柄重复 dlopen 引用计数累积（dart:ffi 无法归还） | 播放会话 | 阶段①注册表接入后改为复用句柄 + 引用计数管理 |
| sqlite | **常驻**（共享实例契约） | `preloadBundledSqlite` | 永不释放 | — | — |

#### ②.1 关键结论（实测修正原规划）
1. **downloader 是唯一「启动即常驻」违反按需的模块**——`bootstrap.dart` 的
   `ref.read(downloadControllerProvider)` 使引擎从启动到退出从不释放，阶段②必须
   先解除（否则「按需」无从谈起）。
2. **scanner 无模块级 destroy**——原规划写「scanner_free」不准确：它只释放
   `scanner_scan` 输出的结果内存，不是库级销毁。scanner 的 Tier 1 只能「句柄
   失效 + 回调关闭」，真实内存归还（C# runtime）必须 Tier 2 子进程化。
3. **scraper/subsonic/fft/downloader 的 Tier 1 native destroy 均已存在**——阶段②
   主要工作是「接入时机 + 引用计数归零 + 绑定失效保护」，不是新增 destroy。
4. **fft 每次播放会话重复 `DynamicLibrary.open`**——同一 .so 被反复打开（句柄
   引用计数累积，Dart 侧无法归还）；阶段①注册表统一 acquire 后复用句柄。

#### ②.2 实施步骤（按依赖顺序）
1. **downloader 解除启动常驻**：
   - `bootstrap.dart` 移除 `ref.read(downloadControllerProvider)` 强制实例化；
     `syncSessions()` 改为「引擎未 init 时记录待注入标志，init 后回放」；
   - `DownloadController` 增加「活跃会话计数」：`ref.listen` 下载页进入/退出
     （或 `activeCount==0 且页面不可见`）→ `engine.dispose()`（Rust destroy）+
     记录待恢复配置；再次进入下载页 → 重新 `init`（`resumeFromHistory` 断点续传）；
   - 注册表 `release(downloader)` 挂到 suspend 路径。
2. **scanner 释放接入**：`startScan` finally 中在 `dispose()` 基础上补
   `NativeModuleRegistry.release(scanner)`（置空 `_lib`/`_progressCallable` 引用、
   计数归零、误用抛 StateError）。
3. **scraper/subsonic/fft**：经注册表 acquire/release 包装既有 dispose；
   `release` = 既有 native destroy + 绑定失效（三者 destroy 均已存在，纯接线）。
4. **释放后误用保护**：所有 wrapper 增加 `_released` 标志，调用任意 FFI 方法抛
   `StateError('模块已释放，请重新 acquire')`；可重新 acquire 恢复。

#### ②.3 互斥双重保证
- 注册表引用计数：`acquire` +1 / `release` -1，归零才执行销毁回调；
- 任务态：scanner `_scanning`、downloader `activeCount`、scraper `scraping`、
  播放会话——释放入口必须同时满足「计数归零 + 无进行中任务」，任一不满足即拒绝。

### 阶段③ Tier 2 子进程隔离（可选）+ 度量验证
- 评估 scanner / downloader 子进程化成本（进度事件走管道）；
- 启动加载耗时 / 峰值内存 / 释放后 RSS 回落度量，验证收益。

---

## 6. 风险与注意
- **共享实例契约**：sqlite 永远不可卸载（dart sqlite3 与 scanner 同库同实例）；
- **悬垂指针**：任何 dlclose 路线在 FFI 函数指针仍被引用时都会崩溃——Tier 1
  不做 dlclose，Tier 2 用进程边界隔离而非进程内 dlclose；
- **释放时机误判**：模块释放须与「进行中任务」互斥（如扫描中不可释放 scanner），
  由引用计数 + 任务态双重保证；
- 各模块加载点迁移为纯行为等价重构，风险低，可分模块逐个切换验证。

---

## 7. 关联文档
- `ffi-libs-layout-plan.md`（已实施）：bundle/native 平铺 + 统一 `NativeLibPaths`，
  本计划的路径基座；
- `lib/services/native_lib_paths.dart`：模块枚举与路径解析（本计划直接复用）。
