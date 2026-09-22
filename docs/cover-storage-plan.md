# 封面存储方案：缩略图一次落盘 + 大图内存直取（对齐 Electron 参考实现）

> 状态：**方案稿 v2 · 2026-09-23**（v1「零常驻」→ 依参考实现修订为「**只落盘一次缩略图**」）
> 目标：封面在**浏览/播放时**不吃内存、不持续写盘；磁盘占用 ≈ 曲数 × 小常数；大图不落盘。
> 参考：`/home/betastudio2/文档/SPlayer-Next/Desktop-only`（Electron）的封面实现（下文 §2）。
> 关联：`media-mindmap.html`（扫描写路径）、`runtime-resource-optimization.md §4.6`。

---

## 1. 现状（我们）

| 环节 | 现状 | 位置 |
|---|---|---|
| 封面落盘 | 按**每曲**写**原始内嵌图** `{dataDir}/cache/covers/{id}.img` | `scanner/ScannerEngine.cs` `TryWriteCover`；`scanner/Program.cs` |
| 刮削封面 | scraper 也有 `coverCacheDir`（外来封面写盘） | `lib/services/scraper/scraper_client.dart`、`core/scraper` |
| Dart 读取 | `/api/music/cover/{id}` → `…/cache/covers/{id}.img` 的 `file://` | `lib/services/scanner/local_track.dart` |
| 大图 | 全屏/水纹背景直接读该 `.img` | `widgets/player/background/*` |
| 内存 | Flutter `ImageCache`（已限 8–1024MiB、按显示尺寸解码） | `runtime-resource-optimization.md §4.6` |

**问题**：存的是**原图**（常 1–5MB）且**全量扫描整批重写**（写放大）。以 5 万曲估算可达**数十 GB**。

---

## 2. 参考实现（Electron Desktop-only）：为什么内存/硬盘几乎不变

代码：`native/audio-engine/src/metadata/cover.rs` / `decoder.rs`、`electron/main/utils/protocol.ts`、`services/scanner.ts`、`ipc/cache.ts`。

```rust
const THUMB_SIZE: u32 = 300;                        // 只存 300px 缩略图
pub fn cover_thumb_path(source, cache_dir)          // 按【源路径 hash】命名
    -> cover_{hash(source):016x}_thumb.jpg
pub fn extract_cover_thumbnail(reader, source, dir) {
    if thumb_file.exists() { return Some(...); }    // 已存在 → 直接返回，不重写
    let data = reader.cover()                       // 内嵌图
        .or_else(|| find_folder_cover(source));     // 回退：同目录 cover 图
    generate_cover_thumbnail(data, thumb_file);     // 缩放到 300px JPEG 落盘
}
pub fn read_attached_pic() -> 原图                 // 注释：供 SMTC/全屏，**不缓存**
```

要点（对应「内存/硬盘几乎不变」）：
1. **只写一次**：`exists()` 命中即返回 → 浏览不再落盘；写标签替换封面时 `remove_file(cover_thumb_path)` **删旧**（`bindings/tags.rs`）。
2. **只存缩略图**：300px JPEG（~20–50KB vs 原图 1–5MB）→ 磁盘**降 1~2 个数量级**，总量 ≈ 曲数 × 小常数。
3. **大图不落盘**：原图「内存直取、短生命周期」（SMTC / 全屏）。
4. **内存由宿主图片缓存承担**：`cache://` 协议把 `app-cache/covers/*.jpg` **流式**交给 Chromium，解码图落在其**有界 LRU**；应用自身不持有。
5. **可观测/可清理**：设置页 `FileCacheManager` 显示 `covers/artists/...` 占用并可清空（`ipc/cache.ts`）。
6. 兜底：无内嵌图 → 同目录封面图（`find_folder_cover`）。

> **结论**：它的本质是「**惰性/一次 + 缩略图 + 路径寻址 + 大图不落盘 + 宿主有界内存缓存**」，**不是**不落盘。这正好解释你的观察。

---

## 3. 我们的目标形态（对齐参考）

| 维度 | 做法 |
|---|---|
| 落盘 | **只落一次 300–600px JPEG 缩略图**：`cover_{hash}_thumb.jpg`（hash 可用源路径或图字节）；`exists` 跳过；封面替换/删除时清理旧缩略图 |
| 大图 | **不落盘**：全屏播放器 / 水纹背景用的原封面走**内存直取**（原生 ABI 返回字节，短生命周期） |
| 生成时机 | **按需**（首次需要该曲封面时）或**扫描时一次**；生成在**原生**（内核 probe 取图 + 缩放；TagLib-only 格式走 scanner） |
| 读取 | Dart 仍走 `file://`（现有 `CoverImage`）；Flutter `ImageCache` 有界且按显示尺寸解码（已做） |
| 内存去重（可选） | 运行时按**图字节 hash**做内存 LRU：同专辑/同曲共享一张解码图（进一步降内存/IO） |
| 可观测 | 设置页「封面缓存」：占用 + 清空（对齐 `FileCacheManager`） |
| 无内嵌图 | 占位；或回退同目录封面图（对齐 `find_folder_cover`） |

> 「零常驻」不再作为目标：**缩略图落盘**比"每次重抽"更省 IO、也符合播放器行为。

---

## 4. ABI / 原生侧

- **取原图（内存，不缓存）**：加法式新增
  ```c
  /* probe-only：seek 到 PICTURE/APIC/covr 读块，不做整解码；两段式（先查长度）。 */
  int zk_cover_read(const char* path, uint8_t* buf, size_t cap,
                    size_t* out_len, char* errbuf, int errbuf_size);
  ```
- **生成缩略图**：可在原生（内核/引擎）完成「取图 → 缩放 → 写 `cover_{hash}_thumb.jpg`」并在返回里给出路径/是否已存在；
  TagLib-only 格式由 scanner 提供同构入口（复用其读图能力，**不再写原图**）。
- 约束：零 JSON、C ABI、MSVC 兼容、`era_` 命名；不做整解码、不新增大块缓冲。

---

## 5. 迁移与清理（我们）

1. **停写原图**：scanner/scraper 不再写 `${id}.img`；改为写缩略图（或交给按需路径）。
2. **回收**：升级时删除旧 `covers/*.img`（原图），改由缩略图目录承载；scraper 外来封面走网络源 + 缩略图缓存。
3. **替换联动**：编辑标签/替换封面 → 删除对应缩略图（对齐 `tags.rs`）。
4. **DB**：`tracks.cover` 继续存缩略图路径/名（`toCacheUrl` 式的映射在 Dart 侧）；**无需改表结构**。
5. **设置项**：「封面缓存」占用/清空。

---

## 6. 验收与度量

- **磁盘**：`covers/` 体积（迁移前原图 vs 迁移后缩略图；应降 1~2 个数量级）；重复浏览**不增长**。
- **扫描**：全量/增量 `scan` wall 与写量（不再重写原图；可跳过已存在缩略图）。
- **观感**：列表/网格滚动加载延迟与掉帧；缩略图 300–600px 是否够清晰（必要时按 DPR 分级：列表 300、全屏走原图内存）。
- **内存**：浏览时内存曲线稳定（Flutter ImageCache 命中/逐出正常）。
- **播放**：无回归（封面路径不参与播放；全屏背景原图内存直取不落盘）。
- 功能：无内嵌图/损坏 → 占位；跨平台（内核 probe / scanner 回退）一致。

---

## 7. 分步落地

| 阶段 | 内容 | 风险 |
|---|---|---|
| **P1** | 落盘从「原图 / 每曲」改为「**缩略图 + hash 命名 + exists 跳过 + 替换删旧**」；迁移删除旧 `.img` | 低 |
| **P2** | 新增 `zk_cover_read`（原图内存直取）+ 缩略图生成入口（内核/scanner）；全屏/背景改走内存直取 | 中 |
| **P3（可选）** | 运行时**内存内容寻址去重 LRU**（同专辑共享解码图）+ 设置项「封面缓存」占用/清空 | 低 |

> 建议 P1 先行（立刻降盘、降写放大），P2 把大图从盘上拿掉，P3 视观感/资源再定。

---

## 8. 关联文档

- `runtime-resource-optimization.md §4.6`（ImageCache 上限 / 按显示尺寸解码）
- `audio-kernel-zig.md §8.4.2`（内核 metadata 快路径）
- `media-mindmap.html`（扫描写路径）
- 参考实现：`Desktop-only/native/audio-engine/src/metadata/cover.rs`、`electron/main/utils/protocol.ts`
