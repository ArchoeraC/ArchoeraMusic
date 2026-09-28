// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * era_log.h — 音频引擎（C）统一日志收口。
 *
 * 宿主（Dart）把 libarchoera_log 的 archoera_log_write 指针经
 * archoera_mediaengine_set_log_sink 注入；引擎各处经 era_log_emit() 输出，
 * 格式/颜色/落盘由统一日志核心处理。未注入时回退 stderr。
 *
 * 级别/函数指针类型与 app/native/log/include/archoera_log.h 对齐（此处本地
 * 声明以避免引擎构建依赖桥接头文件；数值即契约）。
 */
#ifndef ERA_LOG_H
#define ERA_LOG_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 与 archoera_log.h 对齐（勿改数值）。 */
#define ERA_LOG_DEBUG 0
#define ERA_LOG_INFO  1
#define ERA_LOG_WARN  2
#define ERA_LOG_ERROR 3
#define ERA_LOG_FATAL 4

/* 注入的 sink 函数类型（同 archoera_log.h 的 ArchoeraLogFn）。 */
typedef void (*EraLogSink)(int level, const char *tag, const char *message);

/* 注入/注销 sink（fn=NULL 注销）；min_level 以下丢弃。线程安全（启动期一次）。 */
void era_log_set_sink(EraLogSink fn, int min_level);

/* 当前 sink（未注入为 NULL）。 */
EraLogSink era_log_sink(void);

/* 写一条日志：有 sink 交 sink，否则回退 stderr。fmt 为 printf 风格。 */
#if defined(__GNUC__) || defined(__clang__)
__attribute__((format(printf, 3, 4)))
#endif
void era_log_emit(int level, const char *tag, const char *fmt, ...);

#ifdef __cplusplus
}
#endif

/* 便捷宏：tag 可为 NULL（正文自带模块前缀时）。 */
#define ERA_LOGD(tag, ...) era_log_emit(ERA_LOG_DEBUG, tag, __VA_ARGS__)
#define ERA_LOGI(tag, ...) era_log_emit(ERA_LOG_INFO, tag, __VA_ARGS__)
#define ERA_LOGW(tag, ...) era_log_emit(ERA_LOG_WARN, tag, __VA_ARGS__)
#define ERA_LOGE(tag, ...) era_log_emit(ERA_LOG_ERROR, tag, __VA_ARGS__)
#define ERA_LOGF(tag, ...) era_log_emit(ERA_LOG_FATAL, tag, __VA_ARGS__)

#endif /* ERA_LOG_H */
