// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * era_log.c — 引擎统一日志收口实现（见 era_log.h）。
 *
 * 无动态分配、无内存驻留：单次调用栈缓冲格式化后立即交 sink（或 stderr）。
 */
#include "era_log.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#define ERA_LOG_BODY_MAX 2048

/* 启动期注入一次；此后读多写少。volatile 保证可见性（无锁，指针读写原子）。 */
static EraLogSink volatile g_sink = NULL;
static int volatile g_min_level = ERA_LOG_INFO;

void era_log_set_sink(EraLogSink fn, int min_level)
{
    g_min_level = min_level;
    g_sink = fn;
}

EraLogSink era_log_sink(void)
{
    return (EraLogSink)g_sink;
}

void era_log_emit(int level, const char *tag, const char *fmt, ...)
{
    char body[ERA_LOG_BODY_MAX];
    va_list ap;
    EraLogSink sink;

    if (level < g_min_level) return;
    if (fmt == NULL) return;

    va_start(ap, fmt);
    vsnprintf(body, sizeof(body), fmt, ap);
    va_end(ap);

    /* 去掉末尾换行（统一日志核心自行补 '\n'），避免产生空行。 */
    {
        size_t n = strlen(body);
        while (n > 0 && (body[n - 1] == '\n' || body[n - 1] == '\r')) {
            body[--n] = '\0';
        }
    }

    sink = (EraLogSink)g_sink;
    if (sink != NULL) {
        sink(level, tag, body);
        return;
    }
    /* 未注入：stderr 兜底（纯文本，避免引擎完全静默）。 */
    fprintf(stderr, "[%s] %s\n", tag != NULL ? tag : "audio-engine", body);
}
