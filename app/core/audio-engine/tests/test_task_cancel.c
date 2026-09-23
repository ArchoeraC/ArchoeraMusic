// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/*
 * test_task_cancel.c — AS5 协作式取消（zk_task_cancel）C ABI 回归
 *
 * 确定性编排：唯一 worker 被 FIFO 打开阻塞 → 第二个任务排队 → 取消该排队任务 →
 * 释放 FIFO。断言取消任务 wait = -ZK_ABORTED、status = ZK_ABORTED、
 * outcome = ZK_SUBMIT_ERROR；zk_task_cancel(NULL) 安全空操作。
 * 结束打印 ALL PASS。
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef _WIN32
#include <sys/stat.h> /* mkfifo */
#endif

#include "kernel_bridge.h"

#define FRAMES 16

static int write_gold_wav(const char *path) {
    unsigned char hdr[] = {
        'R','I','F','F', 0x34,0x00,0x00,0x00, 'W','A','V','E',
        'f','m','t',' ', 0x10,0x00,0x00,0x00,
        0x01,0x00, 0x01,0x00, 0x40,0x1f,0x00,0x00,
        0x80,0x3e,0x00,0x00, 0x02,0x00, 0x10,0x00,
        'd','a','t','a', 0x20,0x00,0x00,0x00
    };
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    fwrite(hdr, 1, sizeof(hdr), f);
    for (int i = 0; i < FRAMES; i++) {
        int16_t s = (int16_t)i;
        fwrite(&s, 2, 1, f);
    }
    fclose(f);
    return 0;
}

int main(void) {
#if !defined(_WIN32)
    const char *path = "zkcancel_test.wav";
    if (write_gold_wav(path) != 0) { fprintf(stderr, "cannot write wav\n"); return 1; }
    const char *fifo = "zkcancel_block.fifo";
    remove(fifo);
    if (mkfifo(fifo, 0600) != 0) { fprintf(stderr, "mkfifo failed\n"); remove(path); return 1; }

    ZkEngine *h = zk_engine_init(1, 1, 2);
    if (!h) { fprintf(stderr, "zk_engine_init failed\n"); remove(fifo); remove(path); return 1; }

    float b1[64], b2[64];
    /* tblock：唯一 worker 阻塞在 FIFO open；t2：排队在它后面 */
    ZkTask *tblock = zk_submit_decode(h, fifo, b1, 8, NULL);
    if (!tblock) {
        fprintf(stderr, "first (blocking) submit failed\n");
        zk_engine_shutdown(h); remove(fifo); remove(path); return 1;
    }
    ZkTask *t2 = zk_submit_decode(h, path, b2, 8, NULL);
    if (!t2) {
        fprintf(stderr, "queued submit failed\n");
        zk_task_wait(tblock); zk_task_free(tblock);
        zk_engine_shutdown(h); remove(fifo); remove(path); return 1;
    }

    /* 取消仍在排队的 t2（worker 未取走） */
    zk_task_cancel(t2);
    zk_task_cancel(NULL); /* NULL 空操作 */

    /* 释放 FIFO：tblock 以 EOF 失败完工，worker 继而取 t2（已取消 → fail-fast） */
    FILE *wf = fopen(fifo, "w");
    if (wf) fclose(wf);

    long long bn = zk_task_wait(tblock);
    if (bn >= 0) {
        fprintf(stderr, "FIFO decode should fail, got %lld\n", bn);
        zk_task_free(tblock); zk_task_free(t2);
        zk_engine_shutdown(h); remove(fifo); remove(path); return 1;
    }
    zk_task_free(tblock);

    long long cn = zk_task_wait(t2);
    if (cn != -(long long)ZK_ABORTED) {
        fprintf(stderr, "cancelled task wait should be -ZK_ABORTED, got %lld\n", cn);
        zk_task_free(t2); zk_engine_shutdown(h); remove(fifo); remove(path); return 1;
    }
    if (zk_task_status(t2) != ZK_ABORTED) {
        fprintf(stderr, "cancelled task status should be ZK_ABORTED, got %d\n", zk_task_status(t2));
        zk_task_free(t2); zk_engine_shutdown(h); remove(fifo); remove(path); return 1;
    }
    if (zk_task_outcome(t2) != ZK_SUBMIT_ERROR) {
        fprintf(stderr, "cancelled task outcome should be ZK_SUBMIT_ERROR, got %d\n", zk_task_outcome(t2));
        zk_task_free(t2); zk_engine_shutdown(h); remove(fifo); remove(path); return 1;
    }
    zk_task_free(t2);

    zk_engine_shutdown(h);
    remove(fifo);
    remove(path);
    printf("task cancel (queued → -ZK_ABORTED / ERROR) OK\n");
    printf("ALL PASS\n");
    return 0;
#else
    /* Windows：FIFO 编排不可用；取消语义由 Zig 测试覆盖 */
    printf("ALL PASS\n");
    return 0;
#endif
}
