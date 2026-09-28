// ArchoeraMusic 统一日志核心实现
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// 设计要点：
//   - 无动态分配：仅用固定大小的栈/静态缓冲，单行写穿（write-through），
//     不维护内存日志队列 —— 从根上避免「日志驻留内存不裁剪」的泄漏。
//   - 线程安全：进程级互斥体串行化 stderr 与文件写入。
//   - 落盘：**单文件、硬上限（默认 4 MiB）**；达到上限原地截断重写，
//     不生成 .1/.2/.3 等兄弟文件，磁盘占用有界（一个文件）。
//   - 可完全关闭落盘（仅 stderr）。

#include "archoera_log.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <direct.h>
#include <io.h>
#define ERA_PATH_SEP '\\'
#define era_mkdir_one(p) _mkdir(p)
#define era_access(p) _access((p), 0)
#else
#include <pthread.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#define ERA_PATH_SEP '/'
#define era_mkdir_one(p) mkdir((p), 0755)
#define era_access(p) access((p), F_OK)
#endif

/* ── 预算常量（无动态分配的依据）────────────────────────────────── */
#define ERA_LOG_BODY_MAX 3072   /* 正文（含 tag）上限 */
#define ERA_LOG_LINE_MAX 3584   /* 单行上限（前缀 + 正文 + '\n'） */
#define ERA_LOG_PATH_MAX 4096   /* 目录/文件路径上限 */
#define ERA_LOG_BASE_MAX 128    /* 文件名基上限 */
#define ERA_LOG_DEFAULT_MAX_BYTES (4L * 1024L * 1024L) /* 单文件硬上限：4 MiB */

/* ── 进程级状态 ─────────────────────────────────────────────────── */
#if defined(_WIN32)
static SRWLOCK g_lock = SRWLOCK_INIT;
#define ERA_LOCK() AcquireSRWLockExclusive(&g_lock)
#define ERA_UNLOCK() ReleaseSRWLockExclusive(&g_lock)
#else
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
#define ERA_LOCK() pthread_mutex_lock(&g_lock)
#define ERA_UNLOCK() pthread_mutex_unlock(&g_lock)
#endif

static FILE *g_file;          /* NULL = 当前无打开的文件 */
static int g_level = ERA_LOG_INFO;
static int g_color = ERA_LOG_COLOR_AUTO;
static int g_color_effective; /* AUTO 解析后的最终值（惰性） */
static int g_color_resolved;
static long g_file_size;
static long g_max_bytes = ERA_LOG_DEFAULT_MAX_BYTES;
static int g_file_enabled;    /* 1 = 允许落盘（且已配置目录） */
static char g_dir[ERA_LOG_PATH_MAX];
static char g_base[ERA_LOG_BASE_MAX];
static char g_path[ERA_LOG_PATH_MAX];
static int g_ready; /* init 过（即使 dir=NULL） */

/* ── 小工具 ─────────────────────────────────────────────────────── */

static int era_level_clamp(int level) {
    if (level < ERA_LOG_DEBUG) return ERA_LOG_DEBUG;
    if (level > ERA_LOG_FATAL) return ERA_LOG_FATAL;
    return level;
}

static const char *era_level_name(int level) {
    switch (level) {
        case ERA_LOG_DEBUG: return "DEBUG";
        case ERA_LOG_INFO:  return "INFO";
        case ERA_LOG_WARN:  return "WARN";
        case ERA_LOG_ERROR: return "ERROR";
        case ERA_LOG_FATAL: return "FATAL";
        default:            return "INFO";
    }
}

/* 每个级别独立颜色（仅着色级别记号本身）。 */
static const char *era_level_color(int level) {
    switch (level) {
        case ERA_LOG_DEBUG: return "\x1b[90m";    /* 灰 */
        case ERA_LOG_INFO:  return "\x1b[32m";    /* 绿 */
        case ERA_LOG_WARN:  return "\x1b[33m";    /* 黄 */
        case ERA_LOG_ERROR: return "\x1b[31m";    /* 红 */
        case ERA_LOG_FATAL: return "\x1b[1;91m";  /* 加粗亮红 */
        default:            return "";
    }
}

static int era_stderr_is_tty(void) {
#if defined(_WIN32)
    DWORD mode = 0;
    HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
    if (h == INVALID_HANDLE_VALUE || h == NULL) return 0;
    if (!GetConsoleMode(h, &mode)) return 0;
    /* 尝试开启 VT 转义（Windows 10+）；失败则不着色。 */
    if (SetConsoleMode(h, mode | 0x0004 /* ENABLE_VIRTUAL_TERMINAL_PROCESSING */)) {
        return 1;
    }
    return 0;
#else
    return isatty(fileno(stderr)) ? 1 : 0;
#endif
}

/* 递归创建目录（容忍已存在）。成功/已存在返回 0。 */
static int era_mkdir_p(const char *path) {
    char buf[ERA_LOG_PATH_MAX];
    size_t n, i;
    if (path == NULL || path[0] == '\0') return -1;
    n = strlen(path);
    if (n >= sizeof(buf)) return -1;
    memcpy(buf, path, n + 1);
    while (n > 1 && (buf[n - 1] == '/' || buf[n - 1] == '\\')) buf[--n] = '\0';
    for (i = 1; i < n; i++) {
        if (buf[i] == '/' || buf[i] == '\\') {
            char save = buf[i];
            buf[i] = '\0';
            if (buf[0] != '\0' && era_mkdir_one(buf) != 0 && errno != EEXIST) {
                /* 继续尝试，最终以目标目录为准 */
            }
            buf[i] = save;
        }
    }
    if (era_mkdir_one(buf) == 0 || errno == EEXIST) return 0;
    return -1;
}

static void era_join(char *out, size_t cap, const char *dir, const char *name) {
    size_t d = strlen(dir);
    int sep = (d > 0 && (dir[d - 1] == '/' || dir[d - 1] == '\\')) ? 0 : 1;
    snprintf(out, cap, "%s%s%s", dir, sep ? (const char[2]){ERA_PATH_SEP, '\0'} : "", name);
}

static const char *era_base_name(const char *file_base) {
    if (file_base == NULL || file_base[0] == '\0') return "archoera";
    return file_base;
}

/* 由 g_dir/g_base 计算 g_path（锁内调用）。 */
static void era_build_path_locked(void) {
    char file_name[256];
    g_path[0] = '\0';
    if (g_dir[0] == '\0') return;
    snprintf(file_name, sizeof(file_name), "%s.log", era_base_name(g_base));
    /* 预留后缀空间（兼容历史 .N 命名），消除截断告警。 */
    era_join(g_path, sizeof(g_path) - 8, g_dir, file_name);
}

/* 打开目标文件（追加），同步记录当前大小；失败时 g_file=NULL。 */
static void era_open_locked(void) {
    long sz = 0;
    if (g_path[0] == '\0') {
        g_file = NULL;
        return;
    }
    g_file = fopen(g_path, "a");
    if (g_file == NULL) return;
    if (fseek(g_file, 0, SEEK_END) == 0) sz = ftell(g_file);
    if (sz < 0) sz = 0;
    g_file_size = sz;
}

/* 达到上限：原地截断重写（不生成兄弟文件），保留单文件有界。 */
static void era_truncate_locked(void) {
    if (g_file != NULL) {
        fclose(g_file);
        g_file = NULL;
    }
    if (g_path[0] == '\0') return;
    g_file = fopen(g_path, "w");
    g_file_size = 0;
}

static void era_write_file_locked(const char *line, size_t len) {
    if (!g_file_enabled || g_file == NULL) return;
    if (g_file_size + (long)len > g_max_bytes) {
        era_truncate_locked();
        if (g_file == NULL) return;
        /* 截断标记：提示此前的日志已被上限覆盖。 */
        {
            char mark[96];
            int n = snprintf(mark, sizeof(mark),
                             "[---- ---- WARN] log truncated at %ld bytes\n",
                             g_max_bytes);
            if (n > 0) {
                if (fwrite(mark, 1, (size_t)n, g_file) == (size_t)n) {
                    g_file_size += n;
                }
            }
        }
    }
    if (fwrite(line, 1, len, g_file) == len) g_file_size += (long)len;
    fflush(g_file);
}

/* 组装正文（tag + message）到 body；返回写入长度。 */
static size_t era_build_body(char *body, size_t cap, const char *tag,
                             const char *message) {
    int n;
    size_t len;
    if (tag != NULL && tag[0] != '\0') {
        n = snprintf(body, cap, "[%s] %s", tag, message != NULL ? message : "");
    } else {
        n = snprintf(body, cap, "%s", message != NULL ? message : "");
    }
    if (n < 0) return 0;
    len = ((size_t)n >= cap) ? cap - 1 : (size_t)n;
    /* 去掉末尾换行，避免调用方自带 '\n' 时产生空行（本核心自行补 '\n'）。 */
    while (len > 0 && (body[len - 1] == '\n' || body[len - 1] == '\r')) {
        body[--len] = '\0';
    }
    return len;
}

/* ── 公开 API ───────────────────────────────────────────────────── */

int archoera_log_init(const char *dir, const char *file_base, int min_level,
                      int color_mode) {
    int color;
    ERA_LOCK();
    if (g_file != NULL) {
        fclose(g_file);
        g_file = NULL;
    }
    g_level = era_level_clamp(min_level);
    g_color = (color_mode < 0) ? ERA_LOG_COLOR_AUTO
                               : (color_mode > 0 ? ERA_LOG_COLOR_ON
                                                 : ERA_LOG_COLOR_OFF);
    g_color_effective = 0;
    g_color_resolved = 0;
    g_dir[0] = '\0';
    g_base[0] = '\0';
    g_path[0] = '\0';
    g_file_size = 0;
    g_file_enabled = 0;
    g_ready = 1;
    if (dir != NULL && dir[0] != '\0') {
        snprintf(g_dir, sizeof(g_dir), "%s", dir);
        snprintf(g_base, sizeof(g_base), "%s", era_base_name(file_base));
        if (era_mkdir_p(g_dir) == 0) {
            era_build_path_locked();
            /* 旧版多文件轮转残留（.1..N）一次性清理，统一为单文件策略。 */
            if (g_path[0] != '\0') {
                int i;
                for (i = 1; i <= 9; i++) {
                    char sib[ERA_LOG_PATH_MAX];
                    snprintf(sib, sizeof(sib), "%s.%d", g_path, i);
                    remove(sib);
                }
            }
            era_open_locked();
            if (g_path[0] != '\0') g_file_enabled = 1;
        }
    }
    color = (g_color == ERA_LOG_COLOR_AUTO) ? era_stderr_is_tty()
                                            : (g_color == ERA_LOG_COLOR_ON ? 1 : 0);
    g_color_effective = color;
    g_color_resolved = 1;
    ERA_UNLOCK();
    return 0;
}

int archoera_log_set_file_enabled(int on) {
    int old;
    ERA_LOCK();
    old = g_file_enabled;
    if (on) {
        if (g_path[0] == '\0') era_build_path_locked();
        if (g_path[0] != '\0') {
            if (g_file == NULL) era_open_locked();
            g_file_enabled = 1;
        }
    } else {
        if (g_file != NULL) {
            fclose(g_file);
            g_file = NULL;
        }
        g_file_enabled = 0;
    }
    ERA_UNLOCK();
    return old;
}

int archoera_log_file_enabled(void) { return g_file_enabled; }

long archoera_log_set_max_bytes(long bytes) {
    long old;
    ERA_LOCK();
    old = g_max_bytes;
    if (bytes > 0) g_max_bytes = bytes;
    ERA_UNLOCK();
    return old;
}

long archoera_log_max_bytes(void) { return g_max_bytes; }

void archoera_log_shutdown(void) {
    ERA_LOCK();
    if (g_file != NULL) {
        fclose(g_file);
        g_file = NULL;
    }
    g_ready = 0;
    ERA_UNLOCK();
}

void archoera_log_write(int level, const char *tag, const char *message) {
    char body[ERA_LOG_BODY_MAX];
    char line[ERA_LOG_LINE_MAX];
    struct tm tmv;
    time_t now;
    int lv = era_level_clamp(level);

    ERA_LOCK();
    if (lv < g_level) {
        ERA_UNLOCK();
        return;
    }
    if (!g_color_resolved) {
        g_color_effective = (g_color == ERA_LOG_COLOR_AUTO)
                                ? era_stderr_is_tty()
                                : (g_color == ERA_LOG_COLOR_ON ? 1 : 0);
        g_color_resolved = 1;
    }

    now = time(NULL);
#if defined(_WIN32)
    localtime_s(&tmv, &now);
#else
    localtime_r(&now, &tmv);
#endif

    era_build_body(body, sizeof(body), tag, message);

    /* stderr（着色 LEVEL 记号，整行即时 flush）。 */
    if (g_color_effective) {
        snprintf(line, sizeof(line), "[%02d:%02d:%02d %s%s\x1b[0m] %s\n",
                 tmv.tm_hour, tmv.tm_min, tmv.tm_sec, era_level_color(lv),
                 era_level_name(lv), body);
    } else {
        snprintf(line, sizeof(line), "[%02d:%02d:%02d %s] %s\n", tmv.tm_hour,
                 tmv.tm_min, tmv.tm_sec, era_level_name(lv), body);
    }
    fputs(line, stderr);
    fflush(stderr);

    /* 文件（纯文本，无 ANSI）；关闭落盘时跳过。 */
    if (g_file_enabled) {
        if (g_file == NULL && g_path[0] != '\0') era_open_locked();
        snprintf(line, sizeof(line), "[%02d:%02d:%02d %s] %s\n", tmv.tm_hour,
                 tmv.tm_min, tmv.tm_sec, era_level_name(lv), body);
        era_write_file_locked(line, strlen(line));
    }

    ERA_UNLOCK();
}

void archoera_log_writef(int level, const char *tag, const char *fmt, ...) {
    char body[ERA_LOG_BODY_MAX];
    va_list ap;
    if (fmt == NULL) {
        archoera_log_write(level, tag, "");
        return;
    }
    va_start(ap, fmt);
    vsnprintf(body, sizeof(body), fmt, ap);
    va_end(ap);
    archoera_log_write(level, tag, body);
}

int archoera_log_set_level(int min_level) {
    int old;
    ERA_LOCK();
    old = g_level;
    g_level = era_level_clamp(min_level);
    ERA_UNLOCK();
    return old;
}

int archoera_log_set_color(int color_mode) {
    int old;
    ERA_LOCK();
    old = g_color;
    g_color = (color_mode < 0) ? ERA_LOG_COLOR_AUTO
                               : (color_mode > 0 ? ERA_LOG_COLOR_ON
                                                 : ERA_LOG_COLOR_OFF);
    g_color_effective = (g_color == ERA_LOG_COLOR_AUTO)
                            ? era_stderr_is_tty()
                            : (g_color == ERA_LOG_COLOR_ON ? 1 : 0);
    g_color_resolved = 1;
    ERA_UNLOCK();
    return old;
}

int archoera_log_level(void) { return g_level; }
