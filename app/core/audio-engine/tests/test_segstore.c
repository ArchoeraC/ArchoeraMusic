// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/* segstore 单元/并发测试（M1）：单调填充 → 阻塞 pread 对照、随机读、EOF、
 * abort 唤醒阻塞 pread，以及收缩/回收（§6.3/§12）与预算记账助手（§6.1/§6.2）：
 *   - discard_before 前缀整段交还 freelist → used 精确回退、fill 可续写、
 *     已释放区 pread 不崩溃、refill 复用段缓冲（freelist 命中计数）；
 *   - release_all → used==0、同句柄整曲顺序重填全量正确（复用路径）；
 *   - memory_needed_for / can_fit / min_floor / required_ceiling 数值断言。 */
#define _DEFAULT_SOURCE
#define _XOPEN_SOURCE 700
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "segstore.h"

static int g_fail = 0;
#define CHECK(cond, msg)                                                \
    do {                                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, msg); \
            g_fail = 1;                                                 \
        } else {                                                        \
            fprintf(stderr, "ok   %s\n", msg);                          \
        }                                                               \
    } while (0)

static void msleep(long ms)
{
    struct timespec ts = {0, ms * 1000000L};
    nanosleep(&ts, NULL);
}

/* 分块逐段比对 st[off, off+len) 与源 data[off, off+len)。 */
static int region_matches(SegStore *st, const unsigned char *data,
                          unsigned char *scratch, size_t scratch_cap,
                          uint64_t off, size_t len)
{
    uint64_t pos = off;
    size_t left = len;
    while (left > 0) {
        size_t take = left < scratch_cap ? left : scratch_cap;
        intptr_t r = segstore_pread(st, scratch, take, pos);
        if (r != (intptr_t)take) return 0;
        if (memcmp(scratch, data + pos, take) != 0) return 0;
        pos += take;
        left -= take;
    }
    return 1;
}

typedef struct {
    SegStore *st;
    const unsigned char *data;
    size_t len;
} Filler;

static void *filler_fn(void *arg)
{
    Filler *f = (Filler *)arg;
    msleep(40); /* 让消费者先阻塞 */
    size_t off = 0;
    while (off < f->len) {
        size_t step = 9973;
        if (step > f->len - off) step = f->len - off;
        segstore_fill(f->st, off, f->data + off, step);
        off += step;
        msleep(1);
    }
    return NULL;
}

static void *abort_reader(void *arg)
{
    SegStore *s = (SegStore *)arg;
    unsigned char one;
    intptr_t r = segstore_pread(s, &one, 1, 0); /* 无 fill → 阻塞，直到 abort */
    return (void *)r;
}

/* 多次 discard_before / refill：used 精确回退与回升、已释放区 pread 不崩溃、
 * 续写段缓冲全部命中 freelist（复用计数 == 累计释放段数）。 */
static void test_discard_reuse(const unsigned char *data, unsigned char *scratch,
                               size_t scratch_cap)
{
    const size_t S = 4096;
    const unsigned INIT_SEGS = 160;
    SegStore *st = segstore_new(0, S, 0);
    CHECK(st != NULL, "reuse: segstore_new");
    if (!st) return;

    int ok = segstore_fill(st, 0, data, (size_t)INIT_SEGS * S) == 0;
    CHECK(ok, "reuse: 初填 160 段成功");
    CHECK(segstore_used(st) == (uint64_t)INIT_SEGS * S,
          "reuse: 初填 used == 段数×seg_size");
    CHECK(segstore_freelist_len(st) == 0, "reuse: 初填后 freelist 空");

    static const unsigned Fs[] = {8, 24, 10, 40, 16};
    unsigned freed = 0;      /* 累计整段交还数 */
    unsigned written = INIT_SEGS; /* 曾分配段总数（== head/seg_size） */
    uint64_t prev_reuse = 0;

    for (unsigned i = 0; i < sizeof(Fs) / sizeof(Fs[0]); i++) {
        unsigned F = Fs[i];
        char msg[160];

        CHECK(segstore_freelist_len(st) == 0, "reuse: 上轮 refill 已清空 freelist");
        uint64_t exp_used = (uint64_t)(written - freed) * S;
        CHECK(segstore_used(st) == exp_used, "reuse: discard 前 used 精确");

        segstore_discard_before(st, (uint64_t)(freed + F) * S);
        freed += F;
        snprintf(msg, sizeof(msg), "reuse: discard_before 释放 %u 段后 used 回退精确", F);
        CHECK(segstore_used(st) == (uint64_t)(written - freed) * S, msg);
        snprintf(msg, sizeof(msg), "reuse: discard 后 freelist 深度 == %u", F);
        CHECK(segstore_freelist_len(st) == F, msg);

        /* 已释放区（刚交还的整段内）pread：返回错误/0，不崩溃 */
        {
            uint64_t r_off = (uint64_t)(freed - 1) * S + S / 2;
            intptr_t r = segstore_pread(st, scratch, 200, r_off);
            CHECK(r == SEGSTORE_ERR_IO || r == 0,
                  "reuse: 已释放区 pread 返回错误/0 不崩溃");
        }
        /* 保留区读仍正确（首个保留段起点） */
        snprintf(msg, sizeof(msg), "reuse: 保留前缀 pread 与源一致 (cycle %u)", i);
        CHECK(region_matches(st, data, scratch, scratch_cap,
                             (uint64_t)freed * S, 6000),
              msg);

        /* 续写 F 段：缓冲应全部来自 freelist */
        CHECK(segstore_fill(st, (uint64_t)written * S, data + (size_t)written * S,
                            (size_t)F * S) == 0,
              "reuse: discard 后 fill 可续写");
        written += F;
        CHECK(segstore_head(st) == (uint64_t)written * S, "reuse: head 推进");
        CHECK(segstore_used(st) == (uint64_t)(written - freed) * S,
              "reuse: refill 后 used 精确回升");
        CHECK(segstore_freelist_len(st) == 0, "reuse: refill 耗尽 freelist");
        CHECK(segstore_freelist_reuses(st) == prev_reuse + F,
              "reuse: 本次续写全部命中 freelist（复用计数 +F）");
        prev_reuse += F;

        /* 续写块内容对照源 */
        snprintf(msg, sizeof(msg), "reuse: 续写块 pread 与源一致 (cycle %u)", i);
        CHECK(region_matches(st, data, scratch, scratch_cap,
                             (uint64_t)(written - F) * S, (size_t)F * S),
              msg);
    }
    CHECK(segstore_freelist_reuses(st) == freed,
          "reuse: 累计复用次数 == 累计释放段数");
    CHECK(segstore_used(st) == (uint64_t)INIT_SEGS * S,
          "reuse: 终态 used 精确（驻留段数不变）");
    segstore_destroy(st);
}

/* release_all → used==0；同句柄整曲顺序重填全量仍正确（复用路径）。 */
static void test_release_all(const unsigned char *data, unsigned char *scratch,
                             size_t scratch_cap)
{
    const size_t S = 8192;
    const uint64_t N = 100u * (uint64_t)S; /* 100 段 */
    SegStore *st = segstore_new(N, S, 0);
    CHECK(st != NULL, "release_all: segstore_new");
    if (!st) return;

    for (unsigned c = 0; c < 2; c++) {
        char msg[160];
        uint64_t head = 0;
        while (head < N) {
            size_t step = 65537;
            if ((uint64_t)step > N - head) step = (size_t)(N - head);
            CHECK(segstore_fill(st, head, data + head, step) == 0,
                  "release_all: 顺序 fill 成功");
            head += step;
        }
        CHECK(segstore_head(st) == N, "release_all: head==N");
        CHECK(segstore_used(st) == N, "release_all: used==N（全段驻留）");
        CHECK(region_matches(st, data, scratch, scratch_cap, 0, (size_t)N),
              "release_all: 整曲内容与源一致");

        segstore_release_all(st);
        CHECK(segstore_used(st) == 0, "release_all: 释放后 used==0");
        CHECK(segstore_head(st) == 0, "release_all: 释放后 head==0");
        snprintf(msg, sizeof(msg), "release_all: 释放后段缓冲全部入 freelist（%u 段）",
                 100u * (c + 1u));
        CHECK(segstore_freelist_len(st) == N / S, msg);
        snprintf(msg, sizeof(msg), "release_all: 第 %u 轮复用计数对应已完成 refill（%u 段）",
                 c + 1, (unsigned)(c * (N / S)));
        CHECK(segstore_freelist_reuses(st) == (uint64_t)c * (N / S), msg);
    }
    segstore_destroy(st);
}

/* 预算记账助手纯函数数值断言。 */
static void test_budget_helpers(const unsigned char *data)
{
    const uint64_t S = 4096;
    SegStore *st = segstore_new(0, S, 0);
    CHECK(st != NULL, "helpers: segstore_new");
    if (!st) return;

    CHECK(segstore_memory_needed_for(st, 0) == 0, "helpers: needed(0)==0");
    CHECK(segstore_memory_needed_for(st, S) == S, "helpers: needed(S)==S");
    CHECK(segstore_memory_needed_for(st, S + 1) == 2 * S,
          "helpers: needed(S+1)==2S（整段取整）");
    CHECK(segstore_memory_needed_for(st, 2 * S - 1) == 2 * S,
          "helpers: needed(2S-1)==2S");

    /* used==0 → can_fit 仅看 length */
    CHECK(segstore_can_fit(st, S, S), "helpers: can_fit(S, S) 真");
    CHECK(!segstore_can_fit(st, 2 * S, S), "helpers: can_fit(2S, S) 假");
    CHECK(!segstore_can_fit(st, S, S - 1), "helpers: can_fit(S, S-1) 假");
    CHECK(segstore_can_fit(st, 0, 0), "helpers: can_fit(0, 0) 真");

    /* 填 3 段后 used==3S：+length 记账判定 */
    CHECK(segstore_fill(st, 0, data, (size_t)(3 * S)) == 0, "helpers: 填 3 段");
    CHECK(segstore_used(st) == 3 * S, "helpers: used==3S");
    CHECK(segstore_can_fit(st, S, 4 * S), "helpers: 3S+S<=4S 真");
    CHECK(!segstore_can_fit(st, 2 * S, 4 * S), "helpers: 3S+2S>4S 假");
    CHECK(segstore_can_fit(st, 0, 3 * S), "helpers: 满载等号成立");
    segstore_destroy(st);

    /* min_floor / required_ceiling（§6.1/§6.2 常量，默认段 256 KiB → 32 MiB） */
    const uint64_t mib = 1024u * 1024u;
    CHECK(segstore_min_floor(256 * 1024u) == 32u * mib,
          "helpers: min_floor(256KiB)==32MiB");
    CHECK(segstore_min_floor(0) == 32u * mib,
          "helpers: min_floor(0)→默认段==32MiB");
    CHECK(segstore_min_floor(1024u * 1024u) == 32u * mib,
          "helpers: min_floor(1MiB)==32MiB（11MiB 保底窗为整段倍数）");
    CHECK(segstore_min_floor(100 * 1024u) > 32u * mib,
          "helpers: min_floor(100KiB)>32MiB（保底窗整段取整上浮）");
    CHECK(segstore_required_ceiling(32u * mib, 0) == 32u * mib,
          "helpers: required_ceiling(mf,0)==mf");
    CHECK(segstore_required_ceiling(32u * mib, 5u * mib) == 37u * mib,
          "helpers: required_ceiling(32MiB,5MiB)==37MiB");
}

int main(void)
{
    const size_t N = 300000;
    unsigned char *data = (unsigned char *)malloc(N);
    unsigned char *buf = (unsigned char *)malloc(N);
    if (!data || !buf) return 2;
    for (size_t i = 0; i < N; i++) data[i] = (unsigned char)((i * 31 + 7) & 0xFF);

    SegStore *st = segstore_new(N, 0, 0);
    CHECK(st != NULL, "segstore_new");
    if (st) {
        Filler f = {st, data, N};
        pthread_t th;
        CHECK(pthread_create(&th, NULL, filler_fn, &f) == 0, "派生填充线程");
        intptr_t r = segstore_pread(st, buf, N, 0); /* 阻塞直至整首填好 */
        pthread_join(th, NULL);
        CHECK(r == (intptr_t)N && memcmp(buf, data, N) == 0,
              "阻塞 pread 等 fill 后与源一致");
        CHECK(segstore_head(st) == N, "head==N");

        intptr_t r2 = segstore_pread(st, buf, 7000, 123456);
        CHECK(r2 == 7000 && memcmp(buf, data + 123456, 7000) == 0,
              "随机偏移 pread 与源一致");
        intptr_t r3 = segstore_pread(st, buf, 100, N); /* EOF */
        CHECK(r3 == 0, "pread 至 EOF 返 0");
        CHECK(segstore_used(st) > 0, "used>0（预算记账）");
        segstore_destroy(st);
    }

    /* abort 唤醒阻塞 pread */
    {
        SegStore *s2 = segstore_new(0, 0, 0);
        pthread_t th2;
        void *ret = NULL;
        CHECK(pthread_create(&th2, NULL, abort_reader, s2) == 0,
              "派生阻塞 reader");
        msleep(50);
        segstore_abort(s2);
        pthread_join(th2, &ret);
        CHECK((intptr_t)ret == SEGSTORE_ERR_ABORTED,
              "abort 唤醒阻塞 pread → -1");
        segstore_destroy(s2);
    }

    /* 收缩/回收 + 记账助手（独立源缓冲，尺寸放宽避免越界） */
    {
        const size_t BIG = 1024u * 1024u + 65536u;
        unsigned char *big = (unsigned char *)malloc(BIG);
        unsigned char *scratch = (unsigned char *)malloc(65536);
        if (!big || !scratch) return 2;
        for (size_t i = 0; i < BIG; i++)
            big[i] = (unsigned char)((i * 31 + 7) & 0xFF);
        test_discard_reuse(big, scratch, 65536);
        test_release_all(big, scratch, 65536);
        test_budget_helpers(big);
        free(big);
        free(scratch);
    }

    free(data);
    free(buf);
    if (g_fail) {
        fprintf(stderr, "test_segstore: FAILED\n");
        return 1;
    }
    fprintf(stderr, "test_segstore: ALL PASS\n");
    return 0;
}
