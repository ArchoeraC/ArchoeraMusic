/*
 * ArchoeraMusic 统一日志 —— C ABI 契约
 * Copyright (C) 2026 Archoera && BetaStudio2
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * 设计目标（见 docs/unified-logging.md）：
 *   - 全层统一格式：`[HH:mm:ss LEVEL] [tag] message`（tag 可选）；
 *   - INFO/WARN/ERROR/FATAL 各自独立颜色（仅着色 LEVEL 记号，不染整行）；
 *   - 落盘 `<dataDir>/logs/<base>.log`，追加写 + 轮转，**即时写出、无内存驻留**；
 *   - 线程安全；进程内单实例（Dart 载入本库一次，各原生组件经函数指针注入 sink）。
 *
 * 使用方式：
 *   1. 宿主（Dart）载入本库，调 archoera_log_init() 指定目录/级别/着色；
 *   2. 宿主把自己的 archoera_log_write 指针经各组件
 *      `<module>_set_log_sink` 注入（见 archoera_platform.h / 引擎头 / 下载器）；
 *   3. C 组件可直接 include 本头用 archoera_log_writef()。
 *
 * 不引入第三方依赖，不持有任何需释放的内存。
 */
#ifndef ARCHOERA_LOG_H
#define ARCHOERA_LOG_H

#include <stddef.h>

#if defined(_WIN32) || defined(__CYGWIN__)
#if defined(ARCHOERA_LOG_BUILD)
#define ARCHOERA_LOG_API __declspec(dllexport)
#else
#define ARCHOERA_LOG_API __declspec(dllimport)
#endif
#elif defined(__GNUC__) && __GNUC__ >= 4
#define ARCHOERA_LOG_API __attribute__((visibility("default")))
#else
#define ARCHOERA_LOG_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ── 级别 ────────────────────────────────────────────────────────── */
#define ERA_LOG_DEBUG 0
#define ERA_LOG_INFO  1
#define ERA_LOG_WARN  2
#define ERA_LOG_ERROR 3
#define ERA_LOG_FATAL 4

/* 着色模式（archoera_log_init 的 color_mode 参数）。 */
#define ERA_LOG_COLOR_AUTO (-1) /* 仅当 stderr 为终端时着色 */
#define ERA_LOG_COLOR_OFF  0
#define ERA_LOG_COLOR_ON   1

/*
 * 初始化（幂等；重复调用以最后一次为准）。
 *   dir       : 日志目录（UTF-8，可为相对/绝对；NULL = 不落盘，仅 stderr）。
 *   file_base : 文件名基（如 "archoera" → archoera.log）；NULL = "archoera"。
 *   min_level : 最小级别（低于此级别丢弃）；非法值按 INFO。
 *   color_mode: ERA_LOG_COLOR_*。
 * 返回 0 成功；<0 失败（仍可用 stderr 兜底）。
 *
 * 落盘策略：**单文件、硬上限 [archoera_log_set_max_bytes]（默认 4 MiB）**。
 * 达到上限时原地截断重写（写入一条截断标记），**不生成 .1/.2/.3 等兄弟文件**，
 * 磁盘占用有界。可用 [archoera_log_set_file_enabled] 完全关闭落盘。
 */
ARCHOERA_LOG_API int archoera_log_init(const char *dir, const char *file_base,
                                       int min_level, int color_mode);

/* 运行期开启/关闭落盘（使用 init 配置的目录/文件名）。返回旧值（1=开/0=关）。 */
ARCHOERA_LOG_API int archoera_log_set_file_enabled(int on);

/* 当前是否允许落盘。 */
ARCHOERA_LOG_API int archoera_log_file_enabled(void);

/* 设置单文件上限（字节，默认 4 MiB）；<=0 视为默认。返回旧值。 */
ARCHOERA_LOG_API long archoera_log_set_max_bytes(long bytes);

/* 当前单文件上限（字节）。 */
ARCHOERA_LOG_API long archoera_log_max_bytes(void);

/* 关闭：flush/关闭文件句柄。幂等；之后仍可再 init。 */
ARCHOERA_LOG_API void archoera_log_shutdown(void);

/*
 * 写一条日志。线程安全、即时写出（不缓存整行以外的数据）。
 *   level  : ERA_LOG_*；越界按 INFO。
 *   tag    : 模块标签（可为 NULL/空）。
 *   message: UTF-8 文本（可为 NULL）。
 */
ARCHOERA_LOG_API void archoera_log_write(int level, const char *tag,
                                         const char *message);

/* 便捷格式化版本（内部用固定栈缓冲，超长截断）。 */
ARCHOERA_LOG_API void archoera_log_writef(int level, const char *tag,
                                          const char *fmt, ...);

/* 运行时调整最小级别；返回旧值。 */
ARCHOERA_LOG_API int archoera_log_set_level(int min_level);

/* 运行时调整着色模式；返回旧值。 */
ARCHOERA_LOG_API int archoera_log_set_color(int color_mode);

/* 查询当前最小级别（供各组件提前短路昂贵格式化）。 */
ARCHOERA_LOG_API int archoera_log_level(void);

/*
 * sink 函数指针类型：各原生模块通过 `<module>_set_log_sink` 接收宿主注入的
 * 本库 archoera_log_write 指针。message 为已格式化正文（无需再拼接级别/时间）。
 * 回调可在任意线程调用；宿主保证其线程安全。
 */
typedef void (*ArchoeraLogFn)(int level, const char *tag, const char *message);

#ifdef __cplusplus
}
#endif

#endif /* ARCHOERA_LOG_H */
