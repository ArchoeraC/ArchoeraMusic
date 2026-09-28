// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * scraper_log.h — 刮削器（C++ header-only 引擎）统一日志收口。
 *
 * 宿主（Dart）把 libarchoera_log 的 archoera_log_write 指针经
 * archoera_scraper_set_log_sink 注入；刮削器各处经 scraper_log_emit() 输出，
 * 格式/颜色/落盘由统一日志核心处理。未注入时回退 stderr。
 *
 * 级别/函数指针类型与 app/native/log/include/archoera_log.h 对齐（此处本地
 * 声明以避免刮削器构建依赖桥接头文件；数值即契约）。
 *
 * 存储与实现定义在唯一的 .cpp（src/scraper_lib.cpp），本头只做声明；
 * 无动态分配——单次调用栈缓冲（2048）格式化后立即交 sink（或 stderr）。
 */
#ifndef ARCHOERA_SCRAPER_LOG_H
#define ARCHOERA_SCRAPER_LOG_H

namespace archoera::scraper {

/* 与 archoera_log.h 对齐（勿改数值）。 */
#define SCRAPER_LOG_DEBUG 0
#define SCRAPER_LOG_INFO  1
#define SCRAPER_LOG_WARN  2
#define SCRAPER_LOG_ERROR 3
#define SCRAPER_LOG_FATAL 4

/* 注入的 sink 函数类型（同 archoera_log.h 的 ArchoeraLogFn）。 */
using ScraperLogFn = void (*)(int level, const char *tag, const char *message);

/* 注入/注销 sink（fn=NULL 注销）；min_level 以下丢弃。线程安全（启动期一次）。 */
void scraper_log_set_sink(ScraperLogFn fn, int min_level);

/* 当前 sink（未注入为 NULL）。 */
ScraperLogFn scraper_log_sink();

/* 写一条日志：有 sink 交 sink，否则回退 stderr。fmt 为 printf 风格。 */
#if defined(__GNUC__) || defined(__clang__)
__attribute__((format(printf, 3, 4)))
#endif
void scraper_log_emit(int level, const char *tag, const char *fmt, ...);

} // namespace archoera::scraper

/* 便捷宏：tag 可为 NULL（正文自带模块前缀时）。 */
#define SCRAPER_LOGD(tag, ...) \
    ::archoera::scraper::scraper_log_emit(SCRAPER_LOG_DEBUG, tag, __VA_ARGS__)
#define SCRAPER_LOGI(tag, ...) \
    ::archoera::scraper::scraper_log_emit(SCRAPER_LOG_INFO, tag, __VA_ARGS__)
#define SCRAPER_LOGW(tag, ...) \
    ::archoera::scraper::scraper_log_emit(SCRAPER_LOG_WARN, tag, __VA_ARGS__)
#define SCRAPER_LOGE(tag, ...) \
    ::archoera::scraper::scraper_log_emit(SCRAPER_LOG_ERROR, tag, __VA_ARGS__)
#define SCRAPER_LOGF(tag, ...) \
    ::archoera::scraper::scraper_log_emit(SCRAPER_LOG_FATAL, tag, __VA_ARGS__)

#endif /* ARCHOERA_SCRAPER_LOG_H */
