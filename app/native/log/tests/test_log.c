// ArchoeraMusic 统一日志核心 —— 单元测试
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// 覆盖：级别过滤、格式（时间戳/级别/标签）、落盘、轮转。
#include "archoera_log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#include <io.h>
#include <direct.h>
#define ERA_TEST_SEP '\\'
#else
#include <unistd.h>
#define ERA_TEST_SEP '/'
#endif

static int g_fail = 0;
#define CHECK(cond, msg)                                                     \
    do {                                                                     \
        if (!(cond)) {                                                       \
            fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, msg);    \
            g_fail++;                                                        \
        }                                                                    \
    } while (0)

static char *read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    long n;
    char *buf;
    if (f == NULL) return NULL;
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 0) {
        fclose(f);
        return NULL;
    }
    buf = (char *)malloc((size_t)n + 1);
    if (buf == NULL) {
        fclose(f);
        return NULL;
    }
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) {
        free(buf);
        fclose(f);
        return NULL;
    }
    buf[n] = '\0';
    fclose(f);
    return buf;
}

static void join(char *out, size_t cap, const char *dir, const char *name) {
    snprintf(out, cap, "%s%c%s", dir, ERA_TEST_SEP, name);
}

int main(void) {
    char tmpl[4096];
    char *dir;
    char path[4096];
    char *text;

#if defined(_WIN32)
    /* Windows：系统临时目录（%TEMP%），附进程号避免并发冲突。 */
    {
        char base[MAX_PATH];
        DWORD n = GetTempPathA(MAX_PATH, base);
        if (n == 0 || n >= MAX_PATH) {
            fprintf(stderr, "GetTempPath failed\n");
            return 2;
        }
        snprintf(tmpl, sizeof(tmpl), "%sarchoera-log-test-%lu", base,
                 (unsigned long)GetCurrentProcessId());
        _mkdir(tmpl);
        dir = tmpl;
    }
#else
    /* POSIX：系统临时目录（$TMPDIR，缺省 /tmp）。 */
    {
        const char *base = getenv("TMPDIR");
        if (base == NULL || base[0] == '\0') base = "/tmp";
        snprintf(tmpl, sizeof(tmpl), "%s/archoera-log-test-XXXXXX", base);
        dir = mkdtemp(tmpl);
        if (dir == NULL) {
            fprintf(stderr, "mkdtemp failed\n");
            return 2;
        }
    }
#endif

    /* 1) 全级别 + 标签 + 格式（INFO 为最小级别 → DEBUG 被过滤）。 */
    archoera_log_init(dir, "testlog", ERA_LOG_INFO, ERA_LOG_COLOR_OFF);
    archoera_log_write(ERA_LOG_DEBUG, "noise", "filtered-out-marker");
    archoera_log_write(ERA_LOG_INFO, NULL, "initialize");
    archoera_log_write(ERA_LOG_WARN, "resolver",
                       "could not resolve song xxx.mp3:invalid tag");
    archoera_log_write(ERA_LOG_ERROR, NULL, "429 too many requests");
    archoera_log_write(ERA_LOG_FATAL, "kernel", "Kernel Decode Error");
    archoera_log_shutdown();

    join(path, sizeof(path), dir, "testlog.log");
    text = read_file(path);
    CHECK(text != NULL, "log file written");
    if (text != NULL) {
        CHECK(strstr(text, "INFO] initialize") != NULL, "INFO line");
        CHECK(strstr(text, "WARN] [resolver] could not resolve") != NULL,
              "WARN + tag");
        CHECK(strstr(text, "ERROR] 429 too many requests") != NULL, "ERROR line");
        CHECK(strstr(text, "FATAL] [kernel] Kernel Decode Error") != NULL,
              "FATAL + tag");
        CHECK(strstr(text, "filtered-out-marker") == NULL,
              "DEBUG filtered at INFO");
        /* 时间戳形如 [HH:MM:SS ：行首 '[' 后第 3 字符为 ':' */
        CHECK(text[0] == '[' && text[3] == ':', "timestamp prefix HH:MM:SS");
        free(text);
    }

    /* 2) 调低到 DEBUG 后 DEBUG 可见；级别数值过滤生效。 */
    archoera_log_init(dir, "testlog2", ERA_LOG_DEBUG, ERA_LOG_COLOR_OFF);
    archoera_log_set_level(ERA_LOG_DEBUG);
    archoera_log_write(ERA_LOG_DEBUG, "dbg", "debug-visible-marker");
    archoera_log_shutdown();
    join(path, sizeof(path), dir, "testlog2.log");
    text = read_file(path);
    CHECK(text != NULL, "second log file written");
    if (text != NULL) {
        CHECK(strstr(text, "DEBUG] [dbg] debug-visible-marker") != NULL,
              "DEBUG visible when min=DEBUG");
        free(text);
    }

    /* 3) 单文件上限：写超过 4 MiB → 仍只有一个文件，大小有界；无 .1 兄弟文件。 */
    /* 先造一个旧版轮转残留 .1，验证 init 会清理它。 */
    join(path, sizeof(path), dir, "rotest.log.1");
    {
        FILE *seed = fopen(path, "w");
        if (seed != NULL) {
            fputs("legacy-sibling\n", seed);
            fclose(seed);
        }
    }
    archoera_log_init(dir, "rotest", ERA_LOG_INFO, ERA_LOG_COLOR_OFF);
    for (int i = 0; i < 120000; i++) {
        archoera_log_writef(ERA_LOG_INFO, "rot",
                            "line %d paddingpaddingpaddingpaddingpadding", i);
    }
    archoera_log_shutdown();
    join(path, sizeof(path), dir, "rotest.log");
    CHECK(read_file(path) != NULL, "single log file exists");
    join(path, sizeof(path), dir, "rotest.log.1");
    CHECK(read_file(path) == NULL, "no rotated sibling .1 (single file policy)");
    join(path, sizeof(path), dir, "rotest.log");
    {
        /* 单文件上限 4 MiB（+ 截断标记/单行余量）；有界即证明不会无限增长。 */
        FILE *f = fopen(path, "rb");
        long sz = -1;
        if (f != NULL) {
            fseek(f, 0, SEEK_END);
            sz = ftell(f);
            fclose(f);
        }
        CHECK(sz >= 0 && sz <= 4 * 1024 * 1024 + 8192, "single file size bounded");
    }

    /* 4) 关闭落盘：set_file_enabled(0) 后不再写入文件。 */
    archoera_log_init(dir, "notest", ERA_LOG_INFO, ERA_LOG_COLOR_OFF);
    archoera_log_write(ERA_LOG_INFO, "x", "before-disable-marker");
    CHECK(archoera_log_set_file_enabled(0) == 1, "file was enabled");
    CHECK(archoera_log_file_enabled() == 0, "file disabled now");
    for (int i = 0; i < 100; i++) {
        archoera_log_write(ERA_LOG_INFO, "x", "after-disable-marker");
    }
    archoera_log_shutdown();
    join(path, sizeof(path), dir, "notest.log");
    text = read_file(path);
    CHECK(text != NULL, "file created before disable");
    if (text != NULL) {
        CHECK(strstr(text, "before-disable-marker") != NULL,
              "pre-disable line present");
        CHECK(strstr(text, "after-disable-marker") == NULL,
              "no lines written while disabled");
        free(text);
    }

    if (g_fail == 0) fprintf(stderr, "test_log: ALL PASS\n");
    else fprintf(stderr, "test_log: %d FAILED\n", g_fail);
    return g_fail == 0 ? 0 : 1;
}
