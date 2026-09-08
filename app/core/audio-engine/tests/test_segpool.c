// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/* M2.3 进程级段池（跨会话复用）：开启池后 destroy→新会话 fill 复用旧段缓冲，
 * 无逐次 malloc（池复用计数上升）且内容正确；关闭/清空无泄漏。 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "segstore.h"

static int g_fail = 0;
#define CHECK(cond, msg)                                                 \
    do {                                                                 \
        if (!(cond)) {                                                   \
            fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, msg); \
            g_fail = 1;                                                  \
        } else {                                                         \
            fprintf(stderr, "ok   %s\n", msg);                           \
        }                                                                \
    } while (0)

static void *fill_pattern(size_t n)
{
    unsigned char *p = (unsigned char *)malloc(n);
    for (size_t i = 0; i < n; i++) p[i] = (unsigned char)((i * 29 + 5) & 0xFF);
    return p;
}

int main(void)
{
    const size_t N = 3u * 256u * 1024u + 17u; /* 4 段 */
    unsigned char *pat = (unsigned char *)fill_pattern(N);
    if (!pat) return 2;

    segstore_pool_set_cap(64u * 1024u * 1024u); /* 开启进程池 64MB */
    uint64_t before = segstore_pool_reuses();

    SegStore *a = segstore_new(N, 0, 0);
    CHECK(a != NULL, "A new");
    CHECK(segstore_fill(a, 0, pat, N) == 0, "A fill");
    segstore_destroy(a); /* 段缓冲应进入进程池 */

    SegStore *b = segstore_new(N, 0, 0);
    CHECK(b != NULL, "B new");
    CHECK(segstore_fill(b, 0, pat, N) == 0, "B fill（应大量复用池段）");
    unsigned char *out = (unsigned char *)malloc(N);
    CHECK(out != NULL, "buf alloc");
    intptr_t r = segstore_pread(b, out, N, 0);
    CHECK(r == (intptr_t)N && memcmp(out, pat, N) == 0, "B 内容与 A 一致");
    uint64_t after = segstore_pool_reuses();
    CHECK(after > before, "进程池复用计数上升（跨会话免 malloc）");
    segstore_destroy(b);

    /* 关闭池并清空（无泄漏；valgrind 复查） */
    segstore_pool_set_cap(0);

    free(pat);
    free(out);

    if (g_fail) {
        fprintf(stderr, "test_segpool: FAILED\n");
        return 1;
    }
    fprintf(stderr, "test_segpool: ALL PASS\n");
    return 0;
}
