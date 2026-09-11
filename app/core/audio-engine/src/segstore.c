// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "segstore.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define SEG_DEFAULT 256u * 1024u

struct SegStore {
    uint64_t total;      /* 0 = 未知（EOF 由 abort/head 判定） */
    uint64_t head;       /* 已连续填充逻辑长度（单调/可复位） */
    uint64_t released;   /* 已被整段交还的前缀字节水位（恒为 seg_size 倍数） */
    uint64_t budget;     /* 预算（记账/收缩参考） */
    size_t seg_size;
    size_t segs_cap;     /* 段数组容量 */
    uint8_t **segs;      /* 已分配段；seg i 覆盖 [i*seg_size, (i+1)*seg_size) */
    uint64_t used;       /* 驻留段缓冲字节（freelist 中暂存不计） */
    int aborted;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    uint8_t **freelist;  /* 定长段缓冲 free list（§4：复用免逐次 malloc/free 碎片） */
    size_t free_cap;
    size_t free_len;
    uint64_t reuse_count; /* 观测：缓冲自 freelist 复用的累计次数 */
};

/* 段缓冲复用/回收只在“已 abort 或引擎已停、无在途 pread/fill”的调用方保证下
 * 被 discard_before / release_all 使用（docs/audio-memory-source.md §12/§6.3）；
 * 实现内部仍全程持锁并广播：任何与在途操作的交错都不会 use-after-free，
 * 已释放区上的 pread 返回错误/0 而非崩溃。 */

static uint8_t *seg_at(SegStore *s, uint64_t idx)
{
    if (idx >= s->segs_cap) return NULL;
    return s->segs[idx];
}

/* 确保段数组可容纳至索引 idx（含），返回 0 成功 */
static int ensure_segs(SegStore *s, uint64_t idx)
{
    size_t need = (size_t)idx + 1;
    if (need <= s->segs_cap) return 0;
    size_t cap = s->segs_cap ? s->segs_cap : 8;
    while (cap < need) cap *= 2;
    uint8_t **ns = (uint8_t **)realloc(s->segs, cap * sizeof(*ns));
    if (!ns) return -1;
    memset(ns + s->segs_cap, 0, (cap - s->segs_cap) * sizeof(*ns));
    s->segs = ns;
    s->segs_cap = cap;
    return 0;
}

/* 交还一个缓冲进 freelist（持锁调用）。失败返回 -1（调用方须自行 free 以防泄漏）。 */
static int freelist_push(SegStore *s, uint8_t *buf)
{
    if (s->free_len == s->free_cap) {
        size_t cap = s->free_cap ? s->free_cap * 2 : 16;
        uint8_t **nf = (uint8_t **)realloc(s->freelist, cap * sizeof(*nf));
        if (!nf) return -1;
        s->freelist = nf;
        s->free_cap = cap;
    }
    s->freelist[s->free_len++] = buf;
    return 0;
}

/* 复用优先：取一个 freelist 缓冲（持锁调用）；空则返回 NULL 由调用方 malloc。 */
static uint8_t *freelist_pop(SegStore *s)
{
    if (s->free_len == 0) return NULL;
    return s->freelist[--s->free_len];
}

static uint8_t *pool_get(size_t size); /* M2.3 进程池（定义见文件后部） */

SegStore *segstore_new(uint64_t total_hint, size_t seg_size, uint64_t budget)
{
    SegStore *s = (SegStore *)calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->total = total_hint;
    s->seg_size = seg_size ? seg_size : SEG_DEFAULT;
    s->budget = budget ? budget : UINT64_MAX;
    pthread_mutex_init(&s->mu, NULL);
    pthread_cond_init(&s->cv, NULL);
    return s;
}

int segstore_fill(SegStore *s, uint64_t off, const void *data, size_t len)
{
    if (!s || !data || (len && off != s->head)) return SEGSTORE_ERR_IO;
    if (s->aborted) return SEGSTORE_ERR_ABORTED;
    if (len == 0) return 0;

    pthread_mutex_lock(&s->mu);
    uint64_t base = off;
    const uint8_t *src = (const uint8_t *)data;
    size_t left = len;
    while (left > 0) {
        uint64_t seg = base / s->seg_size;
        size_t in_seg = (size_t)(base % s->seg_size);
        size_t take = s->seg_size - in_seg;
        if (take > left) take = left;
        if (ensure_segs(s, seg) != 0) {
            pthread_mutex_unlock(&s->mu);
            return SEGSTORE_ERR_IO;
        }
        if (!seg_at(s, seg)) {
            uint8_t *buf = freelist_pop(s);
            if (buf) {
                s->reuse_count++;
            } else {
                buf = pool_get(s->seg_size); /* M2.3：先查进程池，再 malloc */
                if (!buf) {
                    buf = (uint8_t *)malloc(s->seg_size);
                    if (!buf) {
                        pthread_mutex_unlock(&s->mu);
                        return SEGSTORE_ERR_IO;
                    }
                }
            }
            s->segs[seg] = buf;
            s->used += s->seg_size;
        }
        memcpy(seg_at(s, seg) + in_seg, src, take);
        base += take;
        src += take;
        left -= take;
    }
    s->head = off + len;
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->mu);
    return 0;
}

intptr_t segstore_pread(SegStore *s, void *buf, size_t len, uint64_t off)
{
    if (!s || !buf || !len) return SEGSTORE_ERR_IO;

    pthread_mutex_lock(&s->mu);
    /* 需要 [off, off+len) 就绪：等 head 覆盖或 EOF/abort */
    while (!s->aborted) {
        if (s->total > 0 && off >= s->total) break; /* EOF */
        if (s->released > off) break;   /* 起点已被整段丢弃，永不就绪 */
        if (s->head >= off + len) break;
        if (s->total > 0 && s->head >= s->total) break; /* 全部到 EOF */
        /* 若请求起点已在 total 之外则 EOF；否则等 */
        if (s->total > 0 && s->head >= s->total && off >= s->head) break;
        pthread_cond_wait(&s->cv, &s->mu);
    }
    if (s->aborted) {
        pthread_mutex_unlock(&s->mu);
        return SEGSTORE_ERR_ABORTED;
    }
    /* 请求起点落在已交还（丢弃）区：不崩溃，按错误返回（语义由调用方保证不会
     * 在正常播放中读已释放区）。 */
    if (s->released > off) {
        pthread_mutex_unlock(&s->mu);
        return SEGSTORE_ERR_IO;
    }
    uint64_t avail = s->head; /* 已填充长度 */
    if (s->total > 0 && avail > s->total) avail = s->total;
    if (off >= avail) {
        pthread_mutex_unlock(&s->mu);
        return 0; /* EOF */
    }
    uint64_t readable = avail - off;
    if (readable > len) readable = len;
    size_t want = (size_t)readable;
    uint8_t *dst = (uint8_t *)buf;
    uint64_t pos = off;
    size_t done = 0;
    while (done < want) {
        uint64_t seg = pos / s->seg_size;
        size_t in_seg = (size_t)(pos % s->seg_size);
        size_t take = s->seg_size - in_seg;
        if (take > want - done) take = want - done;
        if (!seg_at(s, seg)) { /* 兜底：驻留区断言缺失，不崩溃 */
            pthread_mutex_unlock(&s->mu);
            return SEGSTORE_ERR_IO;
        }
        memcpy(dst + done, seg_at(s, seg) + in_seg, take);
        pos += take;
        done += take;
    }
    pthread_mutex_unlock(&s->mu);
    return (intptr_t)done;
}

void segstore_set_total(SegStore *s, uint64_t total)
{
    if (!s) return;
    pthread_mutex_lock(&s->mu);
    s->total = total;
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->mu);
}

uint64_t segstore_used(const SegStore *s)
{
    return s ? s->used : 0;
}

uint64_t segstore_head(const SegStore *s)
{
    return s ? s->head : 0;
}

const uint8_t *segstore_base(const SegStore *s, uint64_t *out_len)
{
    if (out_len) *out_len = 0;
    if (!s || !s->segs || !s->segs[0]) return NULL;
    pthread_mutex_lock((pthread_mutex_t *)&s->mu);
    uint64_t head = s->head;
    if (s->total > 0 && head > s->total) head = s->total;
    /* 仅当整个已填充内容落在段 0（seg_size 覆盖全长）且无其它段时，才是连续视图。 */
    const uint8_t *base = NULL;
    if (head > 0 && head <= s->seg_size) {
        base = s->segs[0];
        for (size_t i = 1; i < s->segs_cap; i++) {
            if (s->segs[i]) { base = NULL; break; }
        }
    }
    if (base) *out_len = head;
    pthread_mutex_unlock((pthread_mutex_t *)&s->mu);
    return base;
}

void segstore_discard_before(SegStore *s, uint64_t boundary)
{
    if (!s) return;
    pthread_mutex_lock(&s->mu);
    uint64_t S = (uint64_t)s->seg_size;
    uint64_t rel_seg = s->released / S;          /* 首个仍未交还的段 */
    uint64_t cut = boundary / S;                 /* 段 i start=i*S < boundary ⇔ i < boundary/S */
    uint64_t alloc_segs = (s->head + S - 1) / S; /* 曾分配到的段数 */
    if (cut > alloc_segs) cut = alloc_segs;
    for (uint64_t i = rel_seg; i < cut; i++) {
        uint8_t *buf = (i < s->segs_cap) ? s->segs[i] : NULL;
        if (!buf) continue; /* 兜底：维持不变量，不推进水位 */
        if (freelist_push(s, buf) != 0) free(buf); /* 池满/扩容失败 → 直接回收防泄漏 */
        s->segs[i] = NULL;
        s->used -= S;
        s->released += S;
    }
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->mu);
}

void segstore_release_all(SegStore *s)
{
    if (!s) return;
    pthread_mutex_lock(&s->mu);
    for (size_t i = 0; i < s->segs_cap; i++) {
        if (s->segs[i]) {
            if (freelist_push(s, s->segs[i]) != 0) free(s->segs[i]);
            s->segs[i] = NULL;
        }
    }
    s->used = 0;
    s->head = 0;
    s->released = 0;
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->mu);
}

uint64_t segstore_freelist_reuses(const SegStore *s)
{
    return s ? s->reuse_count : 0;
}

uint64_t segstore_freelist_len(const SegStore *s)
{
    return s ? (uint64_t)s->free_len : 0;
}

uint64_t segstore_memory_needed_for(const SegStore *s, uint64_t length)
{
    if (!s || length == 0) return 0;
    uint64_t S = (uint64_t)s->seg_size;
    uint64_t segs = length / S;
    if (length % S) segs++;
    return segs * S;
}

int segstore_can_fit(const SegStore *s, uint64_t length, uint64_t ceiling)
{
    if (!s) return 0;
    uint64_t need = segstore_memory_needed_for(s, length);
    uint64_t used = segstore_used(s);
    if (used > ceiling) return 0;
    return need <= ceiling - used;
}

/* §6.1 会话级内存硬底线 minFloor 组件基线（保底取值，M1 校准后以常量落库）。
 * Store 必保区(liveAhead) 按整段粒度向上取整（段越大保底占用越高）。
 * 默认 seg_size（256 KiB，liveAhead=11 MiB 恰为整段倍数）→ 恰 32 MiB。 */
uint64_t segstore_min_floor(uint64_t seg_size)
{
    const uint64_t ring       = 2u * 1024u * 1024u;       /* raw ring ~1.5 MB → 兜底 2 MB */
    const uint64_t live_ahead = 11u * 1024u * 1024u;      /* 解码实时 + Store 必保(liveAhead) ~8 MB 段粒度取整 */
    const uint64_t pcm_tail   = 2u * 1024u * 1024u;       /* PCM 实时尾窗 ~2 MB */
    const uint64_t index      = 1u * 1024u * 1024u;       /* 索引缓存 ~1 MB */
    const uint64_t misc       = 16u * 1024u * 1024u;      /* 引擎会话/杂项余量 ~16 MB */
    uint64_t S = seg_size ? (uint64_t)seg_size : SEG_DEFAULT;
    uint64_t store_guarantee = (live_ahead + S - 1) / S * S;
    return ring + store_guarantee + pcm_tail + index + misc;
}

uint64_t segstore_required_ceiling(uint64_t min_floor, uint64_t required_cache)
{
    return min_floor + required_cache;
}

void segstore_abort(SegStore *s)
{
    if (!s) return;
    pthread_mutex_lock(&s->mu);
    s->aborted = 1;
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->mu);
}

/* ── M2.3 进程级段池（跨会话复用，默认关）────────────────────────── */
typedef struct PoolSeg {
    uint8_t *buf;
    size_t size;
} PoolSeg;

/* 进程池锁惰性初始化（CRITICAL_SECTION/POSIX mutex 均不支持可靠静态
 * 初始化；经 pthread_once 保证一次 init，MSVC 走 compat/pthread.h）。 */
static pthread_mutex_t g_pool_mu;
static pthread_once_t g_pool_once = PTHREAD_ONCE_INIT;
static void pool_mu_init(void)
{
    pthread_mutex_init(&g_pool_mu, NULL);
}

/* 进程池访问统一入口：惰性 init（一次）后加锁。 */
static void pool_lock(void)
{
    pthread_once(&g_pool_once, pool_mu_init);
    pthread_mutex_lock(&g_pool_mu);
}

static PoolSeg *g_pool = NULL;
static size_t g_pool_n = 0, g_pool_cap = 0;
static uint64_t g_pool_bytes = 0, g_pool_limit = 0, g_pool_reuses = 0;

static int pool_put(uint8_t *buf, size_t size)
{
    pool_lock();
    if (g_pool_limit == 0 || g_pool_bytes + size > g_pool_limit) {
        pthread_mutex_unlock(&g_pool_mu);
        return 0; /* 池关闭/超限 → 调用方 free */
    }
    if (g_pool_n == g_pool_cap) {
        size_t cap = g_pool_cap ? g_pool_cap * 2 : 16;
        PoolSeg *np = (PoolSeg *)realloc(g_pool, cap * sizeof(*np));
        if (!np) {
            pthread_mutex_unlock(&g_pool_mu);
            return 0;
        }
        g_pool = np;
        g_pool_cap = cap;
    }
    g_pool[g_pool_n].buf = buf;
    g_pool[g_pool_n].size = size;
    g_pool_n++;
    g_pool_bytes += size;
    pthread_mutex_unlock(&g_pool_mu);
    return 1;
}

static uint8_t *pool_get(size_t size)
{
    pool_lock();
    uint8_t *buf = NULL;
    for (size_t i = 0; i < g_pool_n; i++) {
        if (g_pool[i].size == size) {
            buf = g_pool[i].buf;
            g_pool[i] = g_pool[--g_pool_n];
            g_pool_bytes -= size;
            g_pool_reuses++;
            break;
        }
    }
    pthread_mutex_unlock(&g_pool_mu);
    return buf;
}

void segstore_pool_set_cap(uint64_t bytes)
{
    pool_lock();
    g_pool_limit = bytes;
    if (bytes == 0) { /* 关闭并清空 */
        for (size_t i = 0; i < g_pool_n; i++) free(g_pool[i].buf);
        g_pool_n = 0;
        g_pool_bytes = 0;
    }
    pthread_mutex_unlock(&g_pool_mu);
    if (bytes == 0) {
        free(g_pool);
        g_pool = NULL;
        g_pool_cap = 0;
    }
}

uint64_t segstore_pool_reuses(void)
{
    pool_lock();
    uint64_t r = g_pool_reuses;
    pthread_mutex_unlock(&g_pool_mu);
    return r;
}

void segstore_destroy(SegStore *s)
{
    if (!s) return;
    pthread_mutex_lock(&s->mu);
    s->aborted = 1;
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->mu);
    /* 段与 freelist 缓冲：优先归还进程池（cap 内），否则直接 free */
    for (size_t i = 0; i < s->segs_cap; i++) {
        if (s->segs[i]) {
            if (!pool_put(s->segs[i], s->seg_size)) free(s->segs[i]);
            s->segs[i] = NULL;
        }
    }
    for (size_t i = 0; i < s->free_len; i++) {
        if (!pool_put(s->freelist[i], s->seg_size)) free(s->freelist[i]);
    }
    free(s->segs);
    free(s->freelist);
    pthread_mutex_destroy(&s->mu);
    pthread_cond_destroy(&s->cv);
    free(s);
}
