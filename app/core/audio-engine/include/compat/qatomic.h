/**
 * compat/qatomic.h — 跨平台 SPSC ring 原子计数 shim（仅 PlayerCtx 用）
 *
 * 背景：Windows(MSVC) 在 /std:c11 下仍无 conforming 原子支持（C11 只做了
 * 核心语言；<stdatomic.h> 落到 vcruntime_c11_stdatomic.h 直接
 * #error "C atomic support is not enabled"）。本头把 player.c 用到的
 * C11 <stdatomic.h> 操作收敛成一套内存序明确的宏接口：
 *   - 非 MSVC（GCC/Clang，Linux/macOS）：保留 C11 _Atomic/stdatomic，
 *     展开为对应 atomic_*_explicit(…, memory_order_…)，语义与改动前一致；
 *   - MSVC（x64 目标）：volatile + _ReadWriteBarrier（load/store）与
 *     _InterlockedExchangeAdd（underrun 计数），不触碰 stdatomic。
 *
 * 正确性前提（保留此注释约束使用方）：
 *   1. 这些字段是 SPSC 环形缓冲计数 —— 每个变量至多一个写者、另一线程只
 *      读（写侧独占：ring_w 仅引擎线程、ring_r 仅设备音频回调、eof/stop/
 *      underrun 亦单写者），无需 CAS/锁；
 *   2. x86/x64 硬件是 TSO：load→load、store→store 不会被硬件重排，唯一能
 *      破坏顺序的是编译器 —— 故 MSVC 侧只在 acquire load 之后 / release
 *      store 之前各放一道 _ReadWriteBarrier()（编译期屏障，x64 零指令开销）
 *      即满足 SPSC 的 release/acquire（生产者先写 ring[] 再发布 ring_w /
 *      ring_r，消费者按序读回）；
 *   3. MSVC 默认 /volatile:ms 下 volatile 访问本身还有 acquire/release 排
 *      序保证；本头不依赖它（显式屏障兜底 /volatile:iso 场景）。
 *
 * 扩展点（ARM64 Windows 若启用）：TSO 假设不再成立，需把 QA_LOAD_ACQ /
 * QA_STORE_REL 换成带 ld/st 屏障的 MemoryBarrier() 语义，size_t(64bit)
 * 计数在 fetch/rmw 处需 _InterlockedExchangeAdd64；本头当前仅面向 x64。
 *
 * include 路径：源码写 #include "compat/qatomic.h" —— Linux CMake 的
 * /I include 与 MSVC build_windows.bat 的 /I include 均覆盖本目录。
 */
#ifndef COMPAT_QATOMIC_H
#define COMPAT_QATOMIC_H

#if defined(_MSC_VER)

#include <intrin.h>
#include <stddef.h> /* size_t */

/* ── MSVC：plain volatile（x64 下对齐的 4/8 字节访问本身原子）────────── */
/* 统一 size_t 级（ring 计数与标志均用 qa_size；0/1 标志、计数器语义不变）——
   避免 _Generic/多类型分派（MSVC C 支持不完整）。 */
typedef volatile size_t qa_size;

/* acquire load：先 volatile 读回，再 compiler barrier（阻止其后对 ring[]
   的普通读被编译器提升到该读之前）。x64 TSO 保证运行时 load→load 有序。 */
static __inline size_t qa_load_sz(const volatile size_t *p)
{ size_t v = *p; _ReadWriteBarrier(); return v; }

#define QA_LOAD_ACQ(p)     qa_load_sz(p)
#define QA_LOAD_RELAXED(p) qa_load_sz(p)

/* release store：先放 barrier（此前的 ring[]/标志普通写不得下沉到 store
   之后）再 volatile store；x64 TSO 保证该 store 不早于其前面的 store。
   relaxed store 无需屏障（写侧独占，无同步义务）。 */
#define QA_STORE_REL(p, v)      (_ReadWriteBarrier(), *(p) = (v))
#define QA_STORE_RELAXED(p, v)  (*(p) = (v))
#define QA_INIT(p, v)           (*(p) = (v))

/* underrun 统计（relaxed）：InterlockedExchangeAdd64 在 x64 自带 lock 前缀，
   返回值被忽略也保留计数递增语义。 */
#define QA_FETCH_ADD_RELAXED(p, v) \
    ((size_t)_InterlockedExchangeAdd64((volatile long long *)(p), (long long)(v)))

#else /* !_MSC_VER：C11 _Atomic + stdatomic，语义与改动前逐字节一致 */

#include <stdatomic.h>
#include <stddef.h>

typedef _Atomic size_t qa_size;

#define QA_LOAD_ACQ(p)         atomic_load_explicit((p), memory_order_acquire)
#define QA_LOAD_RELAXED(p)     atomic_load_explicit((p), memory_order_relaxed)
#define QA_STORE_REL(p, v)     atomic_store_explicit((p), (v), memory_order_release)
#define QA_STORE_RELAXED(p, v) atomic_store_explicit((p), (v), memory_order_relaxed)
#define QA_FETCH_ADD_RELAXED(p, v) \
    atomic_fetch_add_explicit((p), (v), memory_order_relaxed)
#define QA_INIT(p, v)          atomic_init((p), (v))

#endif /* _MSC_VER */

#endif /* COMPAT_QATOMIC_H */
