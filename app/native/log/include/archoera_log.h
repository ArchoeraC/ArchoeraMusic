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
 * 就地把一行文本中的敏感字段值替换为等长 '*'（SEC-09）。
 * 覆盖 `key=value`（token/cookie/password/... 见实现）与 `key: value` 两种形态；
 * 并针对 Subsonic 单字母查询键 p/t/s 做上下文感知掩码——仅当紧跟 `?`/`&` 且
 * 后接 `=` 时掩码，普通文本（`top=2`/`step=1`/`t=1`）不受影响。大小写不敏感。
 * write 内部已自动对每条日志调用本函数；导出此符号供单测与需要自行预处理的宿主使用。
 * 未知命名不掩码，其余局限见安全评审 SEC-09。
 */
ARCHOERA_LOG_API void archoera_log_scrub(char *text);

/*
 * sink 函数指针类型：各原生模块通过 `<module>_set_log_sink` 接收宿主注入的
 * 本库 archoera_log_write 指针。message 为已格式化正文（无需再拼接级别/时间）。
 * 回调可在任意线程调用；宿主保证其线程安全。
 */
typedef void (*ArchoeraLogFn)(int level, const char *tag, const char *message);

/*
 * 崩溃捕获（CRASH-01）。
 *
 * 原生层（Zig 内核 / C 引擎 / Rust / .NET AOT / 平台桥接）发生段错误、总线错误、
 * 非法指令、浮点异常或 abort 时，进程会被内核直接终止 —— Dart 侧
 * `FlutterError.onError` / `PlatformDispatcher.onError` 根本来不及执行，日志里
 * 只会「说到一半就没了」。本接口安装致命信号处理器，在终止前把
 *
 *   - 信号 / si_code / 故障地址；
 *   - 崩溃线程名；
 *   - 调用栈（模块 + 偏移，尽量含符号）；
 *   - 最近 N 条统一日志（与 archoera.log 同格式）；
 *
 * 写入 `<dir>/crash-<pid>-<epoch>.txt`（同时写 stderr），随后恢复默认处理并
 * 重新抛出信号，**保留 core dump 与既有崩溃语义**（不吞异常、不阻止退出）。
 *
 * 约束：
 *   - 必须在 [archoera_log_init] 之后调用（日志目录默认取 init 的目录）；
 *   - 处理器只使用 async-signal-safe 调用（open/write/close/raise/backtrace），
 *     不取日志互斥量、不分配内存，因此不会因崩溃时持锁而二次死锁；
 *   - 幂等：重复调用只更新报告目录。返回 0 成功，<0 失败（目录不可用等）。
 *
 * dir 为 NULL/空串时沿用 archoera_log_init 的目录；两者都为空则失败
 * （无落盘目录时退化为仅 stderr，不安装处理器）。
 */
ARCHOERA_LOG_API int archoera_crash_install(const char *dir);

/* 卸载崩溃捕获（恢复默认信号处理）。主要供单测/宿主接管场景使用。 */
ARCHOERA_LOG_API void archoera_crash_uninstall(void);

#ifdef __cplusplus
}
#endif

#endif /* ARCHOERA_LOG_H */
