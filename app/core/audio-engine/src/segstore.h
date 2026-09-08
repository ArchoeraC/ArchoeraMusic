// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/* segstore.h — 在线纯内存播放的源字节存储（M1，docs/audio-memory-source.md §4）
 *
 * 模型（保守整曲缓存：§6.2 门禁保证“可驻留才纯内存播放”）：
 *   - 源字节按“单调填充”从 0 起顺序写入（Dart 整曲/合并 Range 拉流）；
 *   - 解码线程 segstore_pread 在 head 不足时阻塞等待 fill（condvar），abort 唤醒；
 *   - 段定长（默认 256 KiB），物理内存按需逐段分配；used 记账供预算/收缩；
 *   - pread 回退/随机访问仅在已填充区（整曲已驻留 → 全部命中）发生。
 *
 * 段缓冲复用（§4 freelist，store 内部）：
 *   - discard_before / release_all 交还的段缓冲进入同 store 的定长段 free list，
 *     后续新段分配优先复用（缺则 malloc），避免逐段 malloc/free 的碎片；
 *   - freelist 中暂存缓冲不计入 used（segstore_used 仅统计驻留段）；
 *   - destroy 清空全部缓冲；本 store 版本不做跨会话进程级段池（§12，M3）。
 *
 * 收缩/回收（§6.3/§12，事件调用，非轮询）：
 *   - segstore_discard_before：整段起始 < boundary 的段交还 freelist 并精确回退
 *     used（语义仅为“停播/切换/预算告警后整体丢弃”等明确回收路径，非播放中淘汰
 *     必保区）；
 *   - segstore_release_all：全部段交还 freelist 并复位 head → used==0（停播/
 *     切歌/§13 弹窗停播后用；同句柄全新会话也可据此整曲重填复用）。
 *   - 调用方保证：discard/release 仅在“已 abort 或引擎已停、无在途 pread/fill”
 *     时调用（见实现文件头注释）；对已释放区 pread 返回错误/0 而非崩溃
 *     （实现仍持锁并广播，避免与在途操作交错）。
 *
 * 预算记账助手（§6.1/§6.2 纯函数，供未来 manager 门禁判定；本层不做 UI/策略决策）：
 *   segstore_memory_needed_for / segstore_can_fit / segstore_min_floor /
 *   segstore_required_ceiling。
 *
 * 线程模型：单生产者(fill) / 单消费者(pread)；abort/discard/release_all 可跨线程。
 * 错误码：>=0 读取字节；-1 aborted；-2 io/参数/越序/oom/读已释放区。
 */

#ifndef ARCHOERASEGSTORE_H
#define ARCHOERASEGSTORE_H

#include <stddef.h>
#include <stdint.h>

/* 导出标记：主库（archoera_mediaengine.so）以 -fvisibility=hidden 编译，segstore
 * 函数须标 default 可见性，Dart 侧 DynamicLibrary.lookup('segstore_new/...') 才能
 * 命中；静态/CLI 链接不受影响。Windows 走 .def 导出表，无需 dllexport。 */
#if defined(_WIN32)
#define SEGSTORE_API
#elif defined(__GNUC__)
#define SEGSTORE_API __attribute__((visibility("default")))
#else
#define SEGSTORE_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SegStore SegStore;

enum {
    SEGSTORE_ERR_ABORTED = -1,
    SEGSTORE_ERR_IO = -2,
};

/* total_hint：已知总长（Content-Length），0=未知（随后 set_total）。
 * seg_size：定长段字节（0 → 默认 256 KiB）。 */
SEGSTORE_API SegStore *segstore_new(uint64_t total_hint, size_t seg_size, uint64_t budget);

/* 顺序填充（必须 off == 当前 head）。返回 0 成功 / <0 错误。 */
SEGSTORE_API int segstore_fill(SegStore *s, uint64_t off, const void *data, size_t len);

/* 位置读取：head 不足以覆盖时阻塞等 fill；返回读取字节（<=len，EOF 为剩余）/
 * <0 错误。abort 后立即返回 SEGSTORE_ERR_ABORTED。起点位于已释放区
 * （discard_before/release_all 交还）时返回 SEGSTORE_ERR_IO。 */
SEGSTORE_API intptr_t segstore_pread(SegStore *s, void *buf, size_t len, uint64_t off);

SEGSTORE_API void segstore_set_total(SegStore *s, uint64_t total);

/* 已驻留字节（预算记账用；freelist 中暂存缓冲不计入）。 */
SEGSTORE_API uint64_t segstore_used(const SegStore *s);

/* 当前已填充逻辑长度（head）。 */
SEGSTORE_API uint64_t segstore_head(const SegStore *s);

/* 整段起始 < boundary 的驻留段交还 freelist 并精确回退 used（前缀丢弃）。 */
SEGSTORE_API void segstore_discard_before(SegStore *s, uint64_t boundary);

/* 交还全部段（含复位 head/released）→ used==0；停播/切歌/复用后 destroy 前可省。 */
SEGSTORE_API void segstore_release_all(SegStore *s);

/* 只读观测钩子（供测试/诊断）：累计 freelist 复用次数 / 当前池深度。 */
SEGSTORE_API uint64_t segstore_freelist_reuses(const SegStore *s);
SEGSTORE_API uint64_t segstore_freelist_len(const SegStore *s);

/* 纯记账：容纳 length 字节所需整段数 × seg_size（0 长度 → 0）。 */
SEGSTORE_API uint64_t segstore_memory_needed_for(const SegStore *s, uint64_t length);

/* 门禁判定：segstore_used + 容纳 length 所需 ≤ ceiling。 */
SEGSTORE_API int segstore_can_fit(const SegStore *s, uint64_t length, uint64_t ceiling);

/* §6.1 会话硬底线 minFloor（随段大小将 Store 必保窗按整段取整；默认段 ≈32 MB）
 * 与 §6.2 requiredCeiling = minFloor + requiredCache。 */
SEGSTORE_API uint64_t segstore_min_floor(uint64_t seg_size);
SEGSTORE_API uint64_t segstore_required_ceiling(uint64_t min_floor, uint64_t required_cache);

SEGSTORE_API void segstore_abort(SegStore *s);
SEGSTORE_API void segstore_destroy(SegStore *s);

#ifdef __cplusplus
}
#endif

#endif /* ARCHOERASEGSTORE_H */
