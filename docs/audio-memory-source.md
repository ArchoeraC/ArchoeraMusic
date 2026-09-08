# 在线播放内存源（Dart 拉流 → 引擎内存源）设计定稿

> 状态：**设计定稿（2026-09-08），未实现**
>
> 背景修正：应用层请求（含音频 URL 解析）本来就在 Dart；音频字节的“取”也应回到
> Dart（不再让引擎自建联网）。2026-09-08 决策：**撤销/搁置**独立 HTTP 模块与
> EraAudio URL 内核方向（C++ BearSSL/TLS、代理、URL gate、Workflow 步骤均不作，
> 已回滚至 3 提交基线）。在线纯内存播放改为「Dart 分段拉流 → C 层内存源
> SegmentStore → FFmpeg/EraAudio 从同一 Store 解码」。
>
> 关联：`docs/audio-memory-playback.md`（解码 PCM 内存播放语义）、
> `docs/audio-kernel-zig.md` §4.3/§16（kernel 不变式，本稿不改文件解码路径）。

## 1. 目标与非目标

- 目标：
  1. 在线 + 内存播放（不落盘）下，播放源字节由 **Dart 网络线程分段拉取**写入进程内
     C 层内存源；引擎（Stable=FFmpeg、EraAudio=Zig）**从内存源解码**，自身不联网；
  2. 内存**有界且可控**：源字节 + 解码 PCM + 输出 ring 统一纳入同一预算（auto 按可用
     内存 0.8 GiB 硬上限 / 用户自定义 / 无上限须警告，语义同 audio-memory-playback §3.3）；
  3. **分片有界**：源字节用定长段 arena + freelist，解码 PCM 用定长块池；废弃数据
     “及时丢弃”（窗口外源段、最旧 PCM 块）。
- 非目标：
  - 不做引擎 HTTP/TLS/代理/重定向（撤销 § 历史工作）；
  - 不改本地文件与 SongCache 命中路径（仍走路径 → 引擎）；
  - 本稿不含歌词/刮削等业务请求。

## 2. 播放源三态（不变）

| 场景 | 播放源形态 |
|---|---|
| 本地文件 / streaming 本地 | 本地路径 → `create(source)`（现状不变） |
| 在线 + SongCache 命中（kugou/netease） | 本地缓存路径 → `create(source)` |
| 在线 + 缓存关 / 未命中 / qqmusic / streaming 在线 | **Dart 拉流 → SegmentStore → 引擎内存源**（本稿） |

## 3. 总体数据流

```
Dart 网络线程（下载/分段 Range）
  └─ fill(segIdx, bytes) 写入 SegmentStore（定长段，跨线程 condvar 通知）
        Engine 解码线程 pread(off,len)
          ├─ 未填：阻塞等待 fill（abort/超时唤醒）
          ├─ FFmpeg：AVIOContext{read/seek} ← Store
          └─ EraAudio：Reader 新形态 ← Store
        → DSP → （内存播放语义不变：PCM 块池 + raw 设备流 / pcm_window FFI）
```

## 4. C 侧 SegmentStore（源字节层）

- 结构：`absStart..absEnd` 逻辑文件视图；固定段大小（建议 256 KiB，编译期常量）；
  段数组（bitmap 标记已填）+ 段缓冲来自 **freelist/arena**（分配一次按需扩容，
  释放段回 freelist，避免逐次 malloc/free 的碎片）。
- API（C，供 Zig/AVIO 消费）：
  - `segstore_create(total, opts)`
  - `segstore_pread(h, buf, len, off) -> ssize_t`（阻塞直至填好/EOF/abort；返回字节或
    错误码，对齐现 `pread` 契约）
  - `segstore_fill(h, off, bytes, len)`（Dart 写线程）
  - `segstore_discard_before(h, abs)`（窗口落后即丢；段整块进 freelist）
  - `segstore_abort / destroy`（唤醒 + 引用归零后释放）
  - `segstore_epoch`（generation：切歌/换源作废旧在途 fill）
  - `segstore_request`（去重/inflight 合并，Dart 侧拉取提示）
- 线程模型：单生产者（Dart 网络线程）单消费者（引擎解码线程）；`mutex+condvar`；
  `abort`/destroy 唤醒阻塞的 `pread`。
- **保留策略 = 内存范围缓存（而非光标滑动丢弃）**：
  - Store 是**已下载范围的内存缓存**，不是“用过即丢”的流窗；
  - **请求去重/合并**：同偏移在途请求只发一次；Dart 合并相邻缺口为大 Range
    （少而大，避免碎请求——防平台 ban）；
  - **默认整曲缓存**：源大小 ≤ 可用预算 → 首次顺序拉一次填满，之后随机跳转/回退
    全部命中内存，**零后续请求**；
  - **必保区（不可淘汰）**：`[decodePos − behindGuarantee, decodePos + liveAhead]`
    内的段、在途/正被解码读取的段**永不被淘汰**；`liveAhead` 覆盖解码前瞻与
    PCM 背压所需，由预算的“保底”部分预留；
  - **容量门禁（保守，不做“渐进兜底”）**：若真实源大小（`Content-Length`）超出
    `ceiling − minFloor`（即无法整首缓存），或 `ceiling < requiredCeiling`（§6.2）→
    **纯内存模式下不采用“播一段丢一段的渐进续传”**，而是拒绝/停播并丢弃全部媒体流，
    弹窗引导改 SongCache/本地或调大上限（§13）。仅当整曲可完整驻留缓存时才进入纯内存
    播放（整曲一次拉取、零请求零淘汰）。
  - **整曲可驻留时源层无淘汰需求**（只做跨会话段池的空闲修剪）；
  - 会话间复用（引用计数）：同曲重播/来回切歌复用已拉字节，进一步减少请求。
- **所有权/生命周期**：Store 段内存归引擎侧 C 所有，Dart 仅 fill 拷贝；引用计数 +
  generation 管理，`store_abort` 唤醒阻塞、切歌即释放（§12）。
- 回退 seek：源层按 §6.2 门禁**整首驻留** → 命中即时；无“因预算淘汰导致缓存缺失”
  的补位重取（预算不足路径已由 §6.3/门禁转停播丢弃）。

## 5. 解码 PCM 层（复用并加固 audio-memory-playback S1）

- `PcmMemBlock` 由“逐 chunk malloc/memmove 淘汰”改为**定长块 + freelist**：
  分配固定容量块（如 2048 帧×ch），淘汰仅归还 freelist（无搬移/无小碎片）；
  索引（pos/epoch/start）语义不变；`pcm_window`/`pcm_epoch` FFI 不变。
- cap/预算沿用 §3.3（auto/自定义/无上限 + 0.8 GiB 硬上限 + append 记账强制淘汰）。

## 6. 统一预算与丢弃协调

- 预算域：SegmentStore 段缓存（已填字节） + PCM 块池（驻留字节） + ring；
- **预算分层**：
  1. **保底层（禁淘汰）**：ring + 解码实时需要的 PCM 尾窗 + Store 必保区
     `[cursor−behindGuarantee, cursor+liveAhead]`——永不裁剪；
  2. **缓存层**：保底层之外的整曲缓存 / 超前预取 / 落后保留，受总预算约束；
- 淘汰协调器（仅针对缓存层，随解码/预算推进）：
  1. Store **LRU/远离游标段**（缓存层内，且不在必保区/在途）；
  2. PCM 最旧块淘汰（对齐现 cap 语义）；
  3. 仍超 → 收窄 aheadPrefetch / Dart 限流。
- 不变量：
  - 总驻留 ≤ min(用户设限, auto 预算)；auto 失败回落保守下限；
  - **不抖动**：解码恒位于必保区，淘汰绝不命中必保/在途段；预算内整曲一次拉取后
    “普通播放+seek”不触发任何淘汰；
  - 常态播放/普通 seek 不触发淘汰 → 不产生额外网络请求（防 ban 第一道闸）；
  - **内存不可信用户的保障**：预算上限可随时被“收缩指令”压到更小值；缓存侧收到收缩
    事件后**同步、立即、非轮询**地按优先级主动裁剪：落后已播区（保留索引）→ 前沿未
    解码预取 → PCM 最旧块；保底层/索引永不动；
  - **内存硬底线（minFloor）**：ring + 解码实时 PCM + Store 必保区 + 索引 = 无法再裁的
    下限。若（用户/auto）上限 < minFloor → 纯内存播放不可行：**启动/收缩时即报错并
    通知用户**（如「内存不足：该曲需 ≥X 内存方可纯内存播放」），不硬撑、不进入“已越界
    再裁”状态；auto 计算亦以「上限=max(可用×比例, minFloor) 但≤0.8 GiB」收敛，绝不因
    查询故障把上限压到 minFloor 之下。
- **全程无轮询**：fill、seek、收缩、淘汰均以事件/条件变量/显式调用驱动（生产=拉取隔离
  线程、解码线程、预算管理器间 notify），不存在周期扫描；仅调试可观测性可有节流日志。

### 6.1 内存需要下限（minFloor）——定值策略与门禁

纯内存播放**必须保证的最小可用内存**，低于它直接拒绝（不硬撑、不越界裁）。

**组件基线（默认取“保底”，可随实现校准为常量并保留给用户可见）**
| 组件 | 默认 | 说明 |
|---|---|---|
| raw 设备 ring | ~1.5 MB | 2–3s×48k·2ch·f32 |
| 解码实时缓冲 + Store 必保区(liveAhead) | ~8 MB | 压缩源前瞻 + pipeline 瞬时缓冲 |
| PCM 实时尾窗（频谱） | ~2 MB | 无频谱时仍保留最小兜底 |
| 容器/seek 索引缓存 | ~1 MB | 常驻不淘汰 |
| 引擎会话/杂项余量 | ~16 MB | 队列/事件/元数据 |
| **sum ≈ minFloor(会话)** | **≈ 32 MB** | |

**门禁（两处）**
1. **会话级**：`userCap > 0` 且 `userCap < minFloor` → create 拒绝并报
   「纯内存模式所需内存下限 X MB > 你所设上限 Y MB」，指引调大或改用文件/在线回退；
   `auto`：上限取 `max(可用×0.1, minFloor)` 再钳到 0.8 GiB（查询失败回落 minFloor，
   绝不跌破）。
2. **设备级**：进程可用内存 < `minFloor × 2`（含余量）→ Dart 启动时即提示
   「系统可用内存不足，纯内存播放不可用，建议使用歌曲缓存/本地文件」，不进入该模式；
   运行期收缩导致 `ceiling < minFloor` → 立即报错停播并通知，不等越界。

> minFloor 不随曲目大小变化（曲目越大只影响“能缓存多少/能否纯内存——超出则拒绝”，
> 不影响“能否启动纯内存”）；真正随内容增长的是缓存预算，受 ceiling 约束。
> 具体数值在 M1 用 RSS/压力用例校准后以常量落库并展示给用户。

### 6.3 内存不足兜底：全量缓存丢弃与降级（防更严重问题）

当判定内存不足（逼近/跌破保障线）时，不能只“裁一部分”，须按阶梯**主动丢弃**，
宁可牺牲体验也要避免把系统拖入 OOM/卡死：

**阶梯（事件驱动，无轮询）**
1. **常规收缩**：落后已播区（保留索引）→ 前沿预取 → PCM 最旧块（§6）；
2. **压力提升**：收窄 `aheadPrefetch` 至最小，PCM 仅留 live 尾窗；
3. **内存不足（跌破 minFloor 保障或收到强收缩指令）→ 全量丢弃播放相关缓存**：
   - Store 段缓存**整体交还**（段池裁剪到近 minFloor 基线）；
   - PCM 块仅保留 live 尾窗，其余全部释放；
   - 索引缓存可视情况保留最小集（§6.1 基线内），其余可弃；
   - 释放字节即时回补预算；
4. **最后兜底**：仍不足 → **连非关键进程内缓存也清**（歌词/图片等内存 LRU，
   经 Dart runtime 接口），并走 §13 红色弹窗 + 停播/回退，不再重试。

**触发点（事件驱动，不设周期扫描）**
- 设置把上限调小 / 外部策略收缩指令；
- 新会话/切歌/预取前评估：`ceiling - minFloor` 不足以覆盖 live+requiredCache；
- 分配/`pread` 失败（内存压力现实信号）；
- Dart runtime 低内存事件（平台/GC 推送）。

**保证**：任意时点总驻留可被收缩到 ≤ minFloor 基线附近；不因“缓存无法裁剪”越界；
低于基线仍无法存活才停止并弹窗。

### 6.4 激进内存策略（默认“激进”，宁丢缓存不冒险）

总原则：**提前、高频、小步释放，绝不逼近上限**；只保必保区，非必要立刻弃。

1. **头部空间（Headroom）**：常态目标 `used ≤ ceiling − headroom`（默认 headroom =
   min(0.25×ceiling, 256 MB)）；不“填满上限再回收”。
2. **只保必要**：
   - Store：仅保「必保 live 窗 + 可视化尾窗所需 + 预算允许的超前预取」；超前预取默认
     很小（解码余量 + 网络 RTT 覆盖），光标前进即释放其落后；
   - PCM：只保留可视化所需尾窗 + 最小余量；可视化关闭时压到最小；
   - 索引：设小上限（默认 ≤ 1 MB）并 LRU，非必要时可弃重建；
   - 进程级段池：上限调小、**空闲即修剪**（mtime/LRU），不等压力事件。
3. **触发更早**：切歌/新会话/设置变更即做一次收敛（丢弃旧曲残留、段池裁剪）；
   预取前先验 `used+inFlight+new ≤ ceiling−headroom`，不满足就不预取或先释放。
4. **绝不以卡顿/碎请求为代价**：激进只作用于“非必保/非在途/索引之外”的层；必保区、
   在途 fill 永不裁；请求护栏（§11）与 §6.2 整曲缓存承诺仍有效——激进是把“缓存留量”
   压小，不是把“播放连续性”做掉。
5. 提供档位（默认激进，可回均衡）便于实测对拍；验收见 §8。

**激进下数值示例（M1 校准占位）**：aheadPrefetch ≈ 源秒数 8–30s 或按 RTT；
PCM 尾窗 ≤ 2–6s；段池空闲上限 ≤ 64 MB；headroom ≥ 1.5×minFloor。

### 6.2 音质挡位单曲保障（内存下限须至少容纳“当前挡位一首正常时长”）

**动机**：纯内存模式的下限必须能完整容纳**当前音质挡位下一首正常时长媒体**的源数据，
否则“播到一半淘汰/续传”成为常态，违背“预算内整曲一次拉满、零请求零淘汰”的承诺。

**典型源大小基准（名义码率 × 正常时长，时长按 6 min）**
| 挡位 | 名义码率 | 6min 源大小 ≈ |
|---|---|---|
| lq | 96 kbps | ~4.3 MB |
| sq | 96 kbps | ~4.3 MB |
| hq | 128 kbps | ~5.8 MB |
| lossless / hi-res | 不可按码率假定 | 以响应 `Content-Length` 为准 |

**保障式（门禁判定，两处一致）**
```
requiredCache = typicalTrack(quality)          // 有损挡位用表；lossless 用真实源大小
requiredCeiling = minFloor + requiredCache
```
- `ceiling ≥ requiredCeiling` → 允许整曲缓存纯内存播放（普通播放/seek 零淘汰零请求）；
- `ceiling < requiredCeiling`（用户/auto 太小或 lossless 超大）：
  1. **保守决策（唯一分支）**：拒绝/停播并丢弃全部媒体流（Store/PCM/在途），弹 §13
     红色弹窗，指引调大上限或改用 SongCache/本地/引擎在线回退；**不做渐进续传**。
- auto 时 `ceiling = max(可用×0.1, minFloor+requiredCache)` 且 ≤0.8 GiB——保证
  “当前挡位正常时长单曲”在可用内存尚可时总能整曲缓存；查询失败回落
  `minFloor+requiredCache`（仍不跌破该保障）。
- lossless/hi-res：以真实 `Content-Length` 参与判定；若超过 `ceiling−minFloor` 则与
  上面一致 → 拒绝/停播 + 丢弃 + 弹窗，不承诺“整曲零淘汰”也不渐进续传。

**验收（并入 §8）**
- 对每个音质挡位：造“正好一首正常时长”用例 → 全程网络请求数 == 1（整曲缓存，零淘汰）；
- `ceiling < minFloor+requiredCache` 或 `源大小 > ceiling−minFloor` 用例 → 停播丢弃 +
  弹窗，无越界、无渐进续传。


## 7. 接入点（FFmpeg / EraAudio）

- FFmpeg（Stable）：pipeline 新增内存源形态——`avio_alloc_context` 的 read/seek 回调
  调用 `segstore_pread`（带 seek：`AVSEEK_SIZE/START` 映射 Store total/cursor）；
  解码/超时/abort 语义与现状一致。
- EraAudio：`io.Reader` 新增形态（Store-backed）复用现有 file 缓存/回溯逻辑；
  `decoder.open` 对“Store 源”走同一 Reader；native_decoder C ABI 增加 mem/store 入口
  （路径入口保持，互不回归）。
- 入口 ABI（建议加法式）：
  `create_mem(store_handle / ptr,len, cfg, …)` 或
  `create_segstore(store, cfg, …)`——具体选型见 §9 开放项；旧 `create(source)` 不动。

## 8. 验收矩阵

1. 本地文件（路径）与 SongCache 命中：两引擎行为逐字节/帧与现状一致（ctest 回归）。
2. 在线+纯内存（缓存关/qqmusic/streaming）：
   - Dart 分段 fill → 引擎 pread 阻塞/唤醒正确；解码到 EOF 帧数与本地文件一致；
   - **整曲缓存命中**：普通播放 + 随机前/后 seek 均命中内存，`pread` 不因 seek 触发
     请求（统计“网络请求次数”== 初始拉取次数）；
   - **LRU 超预算路径**：淘汰段重取走合并 Range + 节流；重取频次 ≤ 护栏上限；
   - `pcm_window` 命中/越出/epoch 语义不变。
3. 内存有界：长播（>budget 内容）驻留 ≈ 预算上限；段池/PCM 块池复用无碎片增长
   （观测 RSS 平台值 + 池空闲命中率）。
4. 预算强制：auto 0.8 GiB 硬上限 / 查询故障回落 / 用户设限优先 / append 记账强制淘汰
   （扩展 test_memory_mode 至源层）。
5. 跨线程：abort/destroy 唤醒阻塞 pread（无挂起）；Dart 网络失败 → error 收敛不挂死。
6. **防 ban 指标**：会话请求数、Range 平均大小、重取率、合并/去重命中率纳入基准；
   禁止在普通播放/seek 下产生“碎请求风暴”。
7. **保守验收**：`源大小 > ceiling−minFloor`（无法整首驻留）→ 拒绝/停播 + 全量丢弃
   + 弹窗，不进入任何“播一段丢一段”状态；整首可驻留曲目解码前向无 stall，请求数==1。
8. **收缩与硬底线验收**：内存逼近上限时下发收缩事件 → 缓存侧同步裁剪（无轮询），
   保底层与索引不裁；构造「上限 < minFloor」用例 → 启动/收缩即报错并给出可读提示，
   不进入越界运行；auto 查询失败也不把上限压到 minFloor 之下。
7. POSIX 全绿 + 既有 ctest/`zig build test` 无回归；Windows/macOS 无平台专属依赖
   （内存源天然跨平台，不再需要 socket/TLS 端口）。

## 9. 分阶段

- **M1** C 引擎内存源：SegmentStore（定长段 freelist + 请求去重/合并 + 预算内整曲缓存/
  LRU 淘汰 + 同步/epoch/abort/refcount + destroy 释放与进程级段池回收）+ FFmpeg avio-mem +
  EraAudio Reader/ABI + 统一预算协调；用本地“预填 Store”回环驱动解码与本地对照。
- **M2** Dart：分段拉流（合并 Range/去重/节流）+ 引用计数会话持有；播放流程在
  “在线+纯内存”切到 create_segstore。
- **M3** 清理与文档：移除 URL/HTTP 遗留引用；audio-memory-*.md 定稿；验收矩阵自动化。

## 10. 开放项（实现前拍板）

1. 入口 ABI：`create_segstore(store_handle,…)`（推荐，Store 句柄由 Dart 预建后交引擎）
   还是 `create_mem(ptr,len,…)`（整首一次性）？本稿推荐 **Store 句柄 + 流式缓存**，
   以支持“预算内整曲缓存、按曲目判定是否可纯内存”而无需强制整首驻留。
2. 段大小与 arena 初始策略（建议 256 KiB，按需翻倍 + freelist 上限）。
3. 网络线程模型：独立 Dart isolate 负责 fill（推荐），与引擎事件泵并行。
4. 缓存保留策略：**预算内整曲缓存（默认）；超大 LRU 淘汰**；`behind` 不再作为独立
   参数（保留由预算/LRU 决定）。

## 11. 随机跳转 / 切歌 / 断流与防 ban 语义

- **随机跳转（seek）**：
  - 命中缓存 → 立即重建解码段（现状语义），无请求；
  - 缓存缺失（仅预算淘汰的超大曲）→ Store 缺口阻塞 + Dart 合并 Range 补位；
  - Store 会话 generation：切歌/换源递增，作废在途 fill；正常 seek 不换 generation。
- **切歌（next/prev）**：destroy 旧会话 + 旧 Store（引用计数归还）；Dart 建新 Store
  并 fill；可预取下一首（M3）。同曲复用缓存（引用计数池）。
- **断流/网络失败**：Dart fill 失败 → Store error → `pread` 返回错误 → 引擎 error 事件；
  `abort/stop` 唤醒阻塞。
- **防 ban 闸（汇总）**：请求去重/inflight 合并 → 预算内整曲一次拉取 → 回退/跳转命中
  缓存零请求 → 超大曲走流式滚动（解码前向零淘汰、仅落后区顺序回收；回退至淘汰区为
  偶发单次合并 Range，节流 + 频次护栏）。

## 12. 切歌立即释放与内存回收

**所有权**：Store 段内存归**引擎侧 C 所有**（Dart 只负责 `fill` 拷贝进段，不长期持字节）。
引用模型：Store 句柄由引擎会话持 1 引用、Dart 网络 isolate 持 1 引用；`store_abort`
唤醒阻塞 `pread` 并作废旧 fill；引用归零 + 解码线程 join 完成后才可释放内存。

**切歌流程（立即丢弃当前曲）**
```
切歌（next/prev/manual）
 ├─ 标记旧会话 retired（generation++）
 ├─ store_abort：唤醒阻塞 pread / 取消在途 fill（Dart 见 retired 即停，不再写）
 ├─ destroy(oldEngine)：abort → join 解码线程 → PCM 块池释放（现状 mem_free）
 ├─ store_release(oldStore)：引用归零后段内存归还进程级段池（见下）
 └─ Dart 释放旧会话引用 → 建新 Store/fill → create(新)
```
- **“立即”口径**：abort/retired 即刻生效（旧曲不再占逻辑句柄、不再参与预算）；
  物理释放紧随 join（解码/网络中断有界 ≤ 数百 ms）；释放顺序 = 唤醒 → join → free，
  杜绝 use-after-free（沿用 destroy join/drain 契约）。

**内存回收（三段）**
1. PCM 块池：会话销毁即释放（现有 `mem_free`），不动。
2. Store 段内存：销毁时整体归还进**进程级定长段池/freelist**（跨会话复用、免逐次
   malloc 碎片）；池设上限，空闲 / 内存压力 / 预算告警时修剪；释放字节即时从统一
   预算记账扣回（切歌后新曲可用全额）。
3. ring/设备缓冲：player stop 现有释放，语义不变。

**不变量**
- generation + 引用计数：旧 fill 永不写入已退役 Store；Store 仅在引用归零且解码线程
  退出后释放；
- 释放即回补预算；
- destroy 后对新 Store 的操作与旧曲完全隔离（事件/句柄与现状一致）。

## 13. 内存不足提示 UI（弹窗 + 红色全局变暗）

- **不用 toast**：内存不足属关键阻塞态，toast 易被忽略 → 一律**模态弹窗**。
- **视觉区分**：现有应用对话框的全局变暗（scrim）为黑色；本弹窗需**单独指定红色
  scrim**，与普通黑 dim 明确区分：
  - Material：`showDialog(..., barrierColor: Color(0x5926..) 红系透明，建议
    Colors.red.withValues(alpha: 0.35))`，仅作用于本弹窗，不影响全局对话框样式；
  - 弹窗内容含：状态（无法/不足）、所需与可用数值、可选操作
    （调大内存上限 / 改用歌曲缓存或本地；无“渐进继续”选项）。
- **触发点（对应 §6.1/§6.2 门禁）**
  1. 设备级可用不足（进入纯内存前）→ 弹窗后回退到缓存/文件模式；
  2. `userCap < minFloor` 或 `ceiling < requiredCeiling`（create/设置变更时）→ 弹窗，
     给出数值与调大/回退选项；
  3. 运行期收缩致 `ceiling < minFloor` → 弹窗 + 停播/降级，不等越界。
- 弹窗须可识别为“内存资源告警”单一种类，便于统一文案与埋点；非关键信息仍可用普通
  toast/横幅。

### 13.1 后台态：系统层通知推送

- **前台**：§13 红色模态弹窗（可操作：调大上限 / 改用缓存·本地）。
- **后台 / 最小化 / 未聚焦**（播放可能仍在进行）：弹窗用户看不到 → 改发**系统通知**
  （Linux libnotify/DBus、Windows toast、macOS UNUserNotificationCenter）：
  - 内容同 §13（状态 + 所需/可用数值 + 简短动作文案）；
  - 点击通知 → 带回前台并展示 §13 红色弹窗（可操作）；
  - 实现属新能力（通知权限/通道），作为 M2 之后的可选增强；核心回退/停播逻辑不依赖它
    （停播仍在后台可靠发生）。
- 优先级：红色弹窗（前台可交互）> 系统通知（后台可接收）> toast（仅非关键）。

## 14. OS 内存压力事件（可选增强；事件驱动，不轮询）

- 目的：在**系统层内存告急**（而非仅我们预算门禁）时第一时间激进回收（§6.3/§6.4），
  并把“是否该收手/降级”交给系统事实。
- 事件源（各平台原生监听，非周期轮询）：
  - Linux：cgroup v2 `memory.events`（`high/oom` 边沿）经 inotify / `memory.pressure`
    （PSI）事件；
  - macOS：`NSWorkspace` 内存压力通知 / `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`；
  - Windows：`CreateMemoryResourceNotification` / `QueryMemoryResourceNotification`
    （可由事件线程 await，不轮询）。
- 动作：收到压力事件 → 触发 §6.3 全量丢弃缓存 → 仍不足再停播 + §13.1 通知/弹窗。
- 约束：无轮询（事件推送）；实现带平台原生小模块并注册，可后期以“可选模块”加载；
  设计核心（预算/门禁/停播）不依赖它——系统事件只是“提前量”的增强信号。

---

## 附：未完成清单（如实标注，待真机/后续实现）

以下为设计定稿中**尚未落地**的点，均非阻塞主链路（已实现面见正文/提交）：

1. **预取下一首（M2.3c）**：对队列下一曲提前拉流/建 store、切歌即复用——需结合 queue/loading
   生命周期与释放竞争，留真机联调。
2. **§13.1 后台态系统通知**：前台红色弹窗已实现；后台/最小化推送（Linux libnotify、
   Windows toast、macOS UNUserNotification）需通知插件/平台通道与权限，未实现。
3. **§14 OS 内存压力事件**：Linux cgroup v2/PSI、macOS memory pressure、Windows
   CreateMemoryResourceNotification 的原生监听未实现（本机无运行环境，不宜盲写）。
4. **弹窗文案 l10n**：§13 弹窗已接 gen_l10n——标题/正文/按钮走 l10n 键；store_source 失败
   原因改为**结构化 `MemorySourceFailDetail`（kind+参数）+ `.error` raw 串**：弹窗按类别用 l10n
   渲染，raw 串仅供日志/测试。✅ 已完成
5. **requiredCeiling 全量预算管理器**：现用简化门禁（默认 64 MiB / env 压低 /
   auto=引擎可用内存策略 + memoryPolicyCacheLimitBytes 纯函数）；§6.1/§6.2 的完整
   ceiling/requiredCeiling 与预算域记账尚未做成独立管理器。
6. **真机手测**：需含 segstore 的引擎 .so 构建后跑 store 会话真解与在线手测清单。
