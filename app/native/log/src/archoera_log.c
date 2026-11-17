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
#include <stdint.h>
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
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#define ERA_PATH_SEP '/'
#define era_mkdir_one(p) mkdir((p), 0755)
#define era_access(p) access((p), F_OK)
#if defined(__has_include)
#if __has_include(<execinfo.h>)
#include <execinfo.h>
#define ERA_HAVE_BACKTRACE 1
#endif
#endif
#if defined(__linux__)
#include <sys/prctl.h>
#endif
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

/* ── 崩溃报告（CRASH-01）────────────────────────────────────────────
 * 最近日志环形缓冲：崩溃处理器在崩溃线程上读取，**不取锁**（可能与正在
 * 写日志的线程交错，最坏读到半行，但不死锁）。每条与落盘行同格式。 */
#define ERA_CRASH_RING_LINES 64
#define ERA_CRASH_RING_LINE_MAX 512
#define ERA_CRASH_ALTSTACK_BYTES (64u * 1024u)
static char g_crash_ring[ERA_CRASH_RING_LINES][ERA_CRASH_RING_LINE_MAX];
static unsigned g_crash_ring_pos;   /* 下一个写入槽位 */
static unsigned g_crash_ring_total; /* 已写入行数（用于首轮未填满时定位） */
static char g_crash_dir[ERA_LOG_PATH_MAX];
static volatile int g_crash_installed;
#if !defined(_WIN32)
static char g_crash_altstack[ERA_CRASH_ALTSTACK_BYTES];
#endif

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

/* 把一条已格式化（纯文本）日志行压入崩溃环形缓冲（调用方持锁）。
 * 不做整槽清零：每行写完即补 '\0'，代价只有一次 memcpy。 */
static void era_crash_ring_push(const char *line) {
    unsigned slot;
    size_t n;
    if (line == NULL) return;
    slot = g_crash_ring_pos % ERA_CRASH_RING_LINES;
    n = strlen(line);
    if (n >= ERA_CRASH_RING_LINE_MAX) n = ERA_CRASH_RING_LINE_MAX - 1;
    memcpy(g_crash_ring[slot], line, n);
    g_crash_ring[slot][n] = '\0';
    g_crash_ring_pos = (g_crash_ring_pos + 1u) % ERA_CRASH_RING_LINES;
    g_crash_ring_total++;
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

/* ── 敏感字段脱敏（SEC-09）──────────────────────────────────────── */
/*
 * 就地把敏感参数的值替换为等长 '*'（不改长度、无动态分配、O(n)）。
 * 覆盖三类形态：
 *   - URL / 表单查询：`key=value`（value 止于 & 空白 引号 ) } ] , ; >）；
 *   - 头 / 字段：`key: value`（value 止于行尾）；
 *   - Subsonic 单字母查询键 p/t/s：仅当处于查询上下文（紧跟 `?`/`&` 且后接
 *     `=`）时掩码，避免误伤普通文本里的 `top=2`/`step=1`/`t=1`。
 * key 匹配大小写不敏感、要求左边界（前一字符非 [A-Za-z0-9_-]）。
 * 未知命名不掩码，属已知接受项，见安全评审 SEC-09。
 */
static int era_is_key_char(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_' || c == '-';
}

/* Subsonic / 通用短键 p(P)/t(T)/s(S)：仅在查询上下文（?/& 前缀且后接 =）掩码。 */
static int era_is_short_query_key(char c) {
    return c == 'p' || c == 'P' || c == 't' || c == 'T' || c == 's' ||
           c == 'S';
}

static int era_eq_ci(const char *a, const char *b, size_t n) {
    size_t i;
    for (i = 0; i < n; i++) {
        char ca = a[i], cb = b[i];
        if (ca >= 'A' && ca <= 'Z') ca = (char)(ca - 'A' + 'a');
        if (cb >= 'A' && cb <= 'Z') cb = (char)(cb - 'A' + 'a');
        if (ca != cb) return 0;
    }
    return 1;
}

static const char *const era_sensitive_keys[] = {
    "token",        "access_token", "refresh_token", "id_token",
    "cookie",       "set-cookie",   "password",      "passwd",
    "pwd",          "secret",       "client_secret", "secret_key",
    "signature",    "sig",          "api_key",       "apikey",
    "api-key",      "access_key",   "authorization", "auth",
    "session",      "sessionid",    "session_id",    "jsessionid",
    "csrf",         "xsrf",
    /* SEC-10：MCP 访问密钥请求头。`-` 属 key 字符，整个 token 为
       `x-archoera-key`，故须按整串登记（登记 `archoera-key` 不命中）。 */
    "x-archoera-key",
    NULL};

static int era_is_sensitive_key(const char *s, size_t n) {
    int i;
    for (i = 0; era_sensitive_keys[i] != NULL; i++) {
        if (strlen(era_sensitive_keys[i]) == n &&
            era_eq_ci(s, era_sensitive_keys[i], n)) {
            return 1;
        }
    }
    return 0;
}

/* 掩码 value（header_mode：仅到行尾；否则到常见分隔符）。返回末尾指针。 */
static char *era_mask_value(char *v, int header_mode) {
    /* 保留分隔符后的前导空白（如 "Cookie: " 的尾随空格），便于阅读；
       该空白不属于敏感值本身。 */
    while (*v == ' ' || *v == '\t') v++;
    while (*v != '\0') {
        char c = *v;
        if (header_mode) {
            if (c == '\n' || c == '\r') break;
        } else if (c == '&' || c == ' ' || c == '\t' || c == '\n' ||
                   c == '\r' || c == '"' || c == '\'' || c == ')' ||
                   c == '}' || c == ']' || c == ',' || c == ';' || c == '>') {
            break;
        }
        *v = '*';
        v++;
    }
    return v;
}

void archoera_log_scrub(char *s) {
    char *p;
    if (s == NULL) return;
    p = s;
    while (*p != '\0') {
        char *q;
        /* 左边界要求：行首或前一字符非 key 字符。 */
        if (p != s && era_is_key_char(p[-1])) {
            p++;
            continue;
        }
        q = p;
        while (era_is_key_char(*q)) q++;
        if (q == p) { /* 当前字符非 key 字符：前进一格，避免死循环 */
            p++;
            continue;
        }
        {
            char *sep = q;
            while (*sep == ' ' || *sep == '\t') sep++;
            /* 单字母查询键 p/t/s：仅限查询上下文，避免误伤普通文本。 */
            if ((size_t)(q - p) == 1 && era_is_short_query_key(p[0]) &&
                p != s && (p[-1] == '?' || p[-1] == '&') && *sep == '=') {
                p = era_mask_value(sep + 1, 0);
                continue;
            }
            if (era_is_sensitive_key(p, (size_t)(q - p))) {
                if (*sep == '=') {
                    p = era_mask_value(sep + 1, 0);
                    continue;
                } else if (*sep == ':') {
                    p = era_mask_value(sep + 1, 1);
                    continue;
                }
            }
        }
        p = q; /* 跳过整个 key 词 */
    }
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
    /* 敏感字段脱敏（SEC-09）：stderr 与落盘一致，含各原生组件注入的 sink 文本。 */
    archoera_log_scrub(body);

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

    /* 崩溃环形缓冲：与落盘同格式（纯文本），供致命信号处理器转储。 */
    snprintf(line, sizeof(line), "[%02d:%02d:%02d %s] %s\n", tmv.tm_hour,
             tmv.tm_min, tmv.tm_sec, era_level_name(lv), body);
    era_crash_ring_push(line);

    /* 文件（纯文本，无 ANSI）；关闭落盘时跳过。 */
    if (g_file_enabled) {
        if (g_file == NULL && g_path[0] != '\0') era_open_locked();
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

/* ── 崩溃捕获（CRASH-01）────────────────────────────────────────────
 * 原生层致命信号（段错误/总线错误/非法指令/浮点异常/abort）默认直接终止进程，
 * Dart 的 onError 不会被调用，日志「说到一半就没了」。本处理器在终止前把
 * 信号、线程名、故障地址、调用栈与最近日志写入独立报告文件，然后恢复默认
 * 处理并重新抛出（保留 core dump 与崩溃语义）。
 *
 * 处理器只使用 async-signal-safe 调用（open/write/close/raise/sigaction +
 * backtrace），不取日志互斥量、不 malloc，避免「崩溃时正持锁」导致死锁。
 */

#if defined(_WIN32)

static LONG WINAPI era_crash_filter(EXCEPTION_POINTERS *ep) {
    char path[ERA_LOG_PATH_MAX];
    wchar_t wpath[ERA_LOG_PATH_MAX];
    char buf[1024];
    HANDLE h;
    DWORD written;
    SYSTEMTIME st;
    DWORD code;
    void *frames[48];
    USHORT nframes;
    int i;

    if (!g_crash_installed) return EXCEPTION_CONTINUE_SEARCH;
    code = (ep && ep->ExceptionRecord) ? ep->ExceptionRecord->ExceptionCode : 0;
    GetLocalTime(&st);
    snprintf(path, sizeof(path), "%s%ccrash-%lu-%lu.txt", g_crash_dir,
             ERA_PATH_SEP, (unsigned long)GetCurrentProcessId(),
             (unsigned long)time(NULL));
    /* 路径为 UTF-8（Dart toNativeUtf8）：必须经 WideChar 打开，否则中文用户名
       下的数据目录会被 ANSI 代码页误解而导致报告静默丢失。 */
    h = INVALID_HANDLE_VALUE;
    if (MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath,
                            (int)(sizeof(wpath) / sizeof(wpath[0]))) > 0) {
        h = CreateFileW(wpath, GENERIC_WRITE, FILE_SHARE_READ, NULL,
                        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    }
    if (h == INVALID_HANDLE_VALUE) {
        h = GetStdHandle(STD_ERROR_HANDLE);
        if (h == INVALID_HANDLE_VALUE || h == NULL) return EXCEPTION_CONTINUE_SEARCH;
    }
#define ERA_WIN_W(s) do { const char *era_s = (s); \
    WriteFile(h, era_s, (DWORD)strlen(era_s), &written, NULL); } while (0)
    ERA_WIN_W("\n=== ArchoeraMusic 崩溃报告 ===\n");
    snprintf(buf, sizeof(buf), "time=%04u-%02u-%02u %02u:%02u:%02u\n",
             (unsigned)st.wYear, (unsigned)st.wMonth, (unsigned)st.wDay,
             (unsigned)st.wHour, (unsigned)st.wMinute, (unsigned)st.wSecond);
    ERA_WIN_W(buf);
    snprintf(buf, sizeof(buf), "pid=%lu tid=%lu\n",
             (unsigned long)GetCurrentProcessId(),
             (unsigned long)GetCurrentThreadId());
    ERA_WIN_W(buf);
    snprintf(buf, sizeof(buf), "exception=0x%08lX address=%p\n",
             (unsigned long)code,
             (ep && ep->ExceptionRecord) ? ep->ExceptionRecord->ExceptionAddress
                                         : (void *)0);
    ERA_WIN_W(buf);
    nframes = CaptureStackBackTrace(0, 48, frames, NULL);
    ERA_WIN_W("--- 调用栈 ---\n");
    for (i = 0; i < (int)nframes; i++) {
        snprintf(buf, sizeof(buf), "#%02d %p\n", i, frames[i]);
        ERA_WIN_W(buf);
    }
    ERA_WIN_W("--- 最近日志 ---\n");
    {
        unsigned total = g_crash_ring_total;
        unsigned n = total < ERA_CRASH_RING_LINES ? total : ERA_CRASH_RING_LINES;
        unsigned start = (g_crash_ring_pos + ERA_CRASH_RING_LINES - n) % ERA_CRASH_RING_LINES;
        for (i = 0; i < (int)n; i++) {
            const char *l = g_crash_ring[(start + (unsigned)i) % ERA_CRASH_RING_LINES];
            ERA_WIN_W(l);
        }
    }
    ERA_WIN_W("=== 报告结束 ===\n");
#undef ERA_WIN_W
    if (h != GetStdHandle(STD_ERROR_HANDLE)) {
        FlushFileBuffers(h);
        CloseHandle(h);
    } else {
        FlushFileBuffers(h);
    }
    return EXCEPTION_CONTINUE_SEARCH; /* 交给系统默认处理（保留 WER/core） */
}

int archoera_crash_install(const char *dir) {
    if (dir != NULL && dir[0] != '\0') {
        snprintf(g_crash_dir, sizeof(g_crash_dir), "%s", dir);
    } else if (g_dir[0] != '\0') {
        snprintf(g_crash_dir, sizeof(g_crash_dir), "%s", g_dir);
    } else {
        return -1;
    }
    (void)era_mkdir_p(g_crash_dir);
    SetUnhandledExceptionFilter(era_crash_filter);
    g_crash_installed = 1;
    archoera_log_writef(ERA_LOG_INFO, "crash",
                        "崩溃捕获已启用：报告目录 %s", g_crash_dir);
    return 0;
}

void archoera_crash_uninstall(void) {
    if (!g_crash_installed) return;
    SetUnhandledExceptionFilter(NULL);
    g_crash_installed = 0;
}

#else /* POSIX */

/* 小工具：全部 async-signal-safe（仅 write/strlen 循环）。 */
static void era_cw(int fd, const char *s) {
    size_t n;
    if (s == NULL) return;
    n = strlen(s);
    while (n > 0) {
        ssize_t w = write(fd, s, n);
        if (w <= 0) return;
        s += (size_t)w;
        n -= (size_t)w;
    }
}

static void era_cw_dec(int fd, unsigned long long v) {
    char b[32];
    int i = (int)sizeof(b);
    if (v == 0) {
        b[--i] = '0';
    } else {
        while (v > 0 && i > 0) {
            b[--i] = (char)('0' + (int)(v % 10u));
            v /= 10u;
        }
    }
    while (i < (int)sizeof(b)) {
        ssize_t w = write(fd, &b[i], (size_t)((int)sizeof(b) - i));
        if (w <= 0) return;
        i += (int)w;
    }
}

static void era_cw_hex(int fd, unsigned long long v) {
    static const char digits[] = "0123456789abcdef";
    char b[2 + 16];
    int i;
    b[0] = '0';
    b[1] = 'x';
    for (i = 0; i < 16; i++) {
        b[2 + i] = digits[(v >> ((15 - i) * 4)) & 0xFu];
    }
    {
        ssize_t w = write(fd, b, sizeof(b));
        (void)w;
    }
}

static const char *era_sig_name(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGILL:  return "SIGILL";
        case SIGFPE:  return "SIGFPE";
        case SIGABRT: return "SIGABRT";
        case SIGSYS:  return "SIGSYS";
        default:      return "SIG?";
    }
}

static void era_crash_handler(int sig, siginfo_t *si, void *uc) {
    char path[ERA_LOG_PATH_MAX];
    char tname[64];
    int fd;
    int i;
    unsigned total, n, start;

    (void)uc;
    snprintf(path, sizeof(path), "%s%ccrash-%lu-%lu.txt", g_crash_dir,
             ERA_PATH_SEP, (unsigned long)getpid(), (unsigned long)time(NULL));
    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) fd = 2; /* 报告文件不可写：至少写到 stderr */

    tname[0] = '\0';
#if defined(__linux__)
    /* prctl 读取本线程名（glibc 的 pthread_getname_np 需 _GNU_SOURCE）。 */
    if (prctl(PR_GET_NAME, (unsigned long)tname, 0UL, 0UL, 0UL) != 0) tname[0] = '\0';
#elif defined(__APPLE__)
    if (pthread_getname_np(pthread_self(), tname, sizeof(tname)) != 0) tname[0] = '\0';
#endif

    era_cw(fd, "\n=== ArchoeraMusic 崩溃报告 ===\n");
    era_cw(fd, "time=");
    era_cw_dec(fd, (unsigned long long)time(NULL));
    era_cw(fd, " pid=");
    era_cw_dec(fd, (unsigned long long)getpid());
    era_cw(fd, " signal=");
    era_cw_dec(fd, (unsigned long long)sig);
    era_cw(fd, " (");
    era_cw(fd, era_sig_name(sig));
    era_cw(fd, ")\n");
    if (si != NULL) {
        era_cw(fd, "si_code=");
        era_cw_dec(fd, (unsigned long long)(long long)si->si_code);
        era_cw(fd, " fault_addr=");
        era_cw_hex(fd, (unsigned long long)(uintptr_t)si->si_addr);
        era_cw(fd, "\n");
    }
    era_cw(fd, "thread=");
    era_cw(fd, tname[0] != '\0' ? tname : "<unnamed>");
    era_cw(fd, "\n");

#if defined(ERA_HAVE_BACKTRACE)
    era_cw(fd, "--- 调用栈（module + offset）---\n");
    {
        void *frames[64];
        int nf = backtrace(frames, 64);
        if (nf > 0) backtrace_symbols_fd(frames, nf, fd);
    }
#else
    era_cw(fd, "--- 调用栈不可用（缺 execinfo.h）---\n");
#endif

    era_cw(fd, "--- 最近日志 ---\n");
    total = g_crash_ring_total;
    n = total < ERA_CRASH_RING_LINES ? total : ERA_CRASH_RING_LINES;
    start = (g_crash_ring_pos + ERA_CRASH_RING_LINES - n) % ERA_CRASH_RING_LINES;
    for (i = 0; i < (int)n; i++) {
        era_cw(fd, g_crash_ring[(start + (unsigned)i) % ERA_CRASH_RING_LINES]);
    }
    era_cw(fd, "=== 报告结束 ===\n");

    if (fd > 2) {
        if (fsync(fd) != 0) { /* 忽略：报告已写出即达成目的 */ }
        close(fd);
    } else {
        if (fsync(2) != 0) { /* 忽略 */ }
    }

    /* 恢复默认处理、解除阻塞后重新抛出：保留 core dump / 退出码语义。 */
    {
        struct sigaction dfl;
        sigset_t unblock;
        memset(&dfl, 0, sizeof(dfl));
        dfl.sa_handler = SIG_DFL;
        sigemptyset(&dfl.sa_mask);
        sigaction(sig, &dfl, NULL);
        sigemptyset(&unblock);
        sigaddset(&unblock, sig);
        sigprocmask(SIG_UNBLOCK, &unblock, NULL);
    }
    raise(sig);
    _exit(128 + sig); /* 理论上不会到达（除非 raise 被忽略） */
}

int archoera_crash_install(const char *dir) {
    static const int kSigs[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT};
    struct sigaction sa;
    stack_t ss;
    size_t i;

    if (dir != NULL && dir[0] != '\0') {
        snprintf(g_crash_dir, sizeof(g_crash_dir), "%s", dir);
    } else if (g_dir[0] != '\0') {
        snprintf(g_crash_dir, sizeof(g_crash_dir), "%s", g_dir);
    } else {
        return -1;
    }
    if (era_mkdir_p(g_crash_dir) != 0) return -1;

    if (!g_crash_installed) {
        /* 备用信号栈：栈溢出导致的 SIGSEGV 仍能进入处理器。 */
        memset(&ss, 0, sizeof(ss));
        ss.ss_sp = g_crash_altstack;
        ss.ss_size = sizeof(g_crash_altstack);
        ss.ss_flags = 0;
        (void)sigaltstack(&ss, NULL);
    }

    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = era_crash_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);

    for (i = 0; i < sizeof(kSigs) / sizeof(kSigs[0]); i++) {
        (void)sigaction(kSigs[i], &sa, NULL);
    }
    g_crash_installed = 1;
    archoera_log_writef(ERA_LOG_INFO, "crash",
                        "崩溃捕获已启用：报告目录 %s", g_crash_dir);
    return 0;
}

void archoera_crash_uninstall(void) {
    static const int kSigs[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT};
    size_t i;
    if (!g_crash_installed) return;
    for (i = 0; i < sizeof(kSigs) / sizeof(kSigs[0]); i++) {
        struct sigaction dfl;
        memset(&dfl, 0, sizeof(dfl));
        dfl.sa_handler = SIG_DFL;
        sigemptyset(&dfl.sa_mask);
        sigaction(kSigs[i], &dfl, NULL);
    }
    g_crash_installed = 0;
}

#endif /* _WIN32 */
