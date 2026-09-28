// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// Package logging 为 Go 侧（c-shared 服务端）提供统一日志桥。
//
// 宿主 Dart 加载 libarchoera_log 后，把 archoera_log_write 指针经
// archoera_subsonic_set_log_sink 注入（见 lib_subsonic.go）；本包用 cgo
// 保存该函数指针，所有 Go 日志经 C.sub_log_emit 回调统一 sink
// （格式/分级着色/落盘由 libarchoera_log 完成）。
//
// 未注入 sink 时（standalone / 旧版库 / 注入前）回退 os.Stderr，格式与核心
// 一致：`[HH:mm:ss LEVEL] [tag] message`。级别数值对齐 archoera_log.h：
// 0=DEBUG 1=INFO 2=WARN 3=ERROR 4=FATAL。
package logging

/*
#include <stdlib.h>

// 与 app/native/log/include/archoera_log.h 的 ArchoeraLogFn 对齐。
typedef void (*archoera_log_fn)(int level, const char *tag, const char *message);

static archoera_log_fn g_log_sink;
static int g_log_min = 1; // INFO

static void sub_log_set(archoera_log_fn f, int m) { g_log_sink = f; g_log_min = m; }
static void sub_log_set_ptr(void *f, int m) { sub_log_set((archoera_log_fn)f, m); }
static void sub_log_emit(int level, const char *tag, const char *msg) {
    if (g_log_sink != 0 && level >= g_log_min) g_log_sink(level, tag, msg);
}
static void *sub_log_get_sink(void) { return (void *)g_log_sink; }
static int sub_log_get_min(void) { return g_log_min; }
static int sub_log_has_sink(void) { return g_log_sink != 0; }
*/
import "C"

import (
	"fmt"
	"os"
	"time"
	"unsafe"
)

// 级别常量（对齐 archoera_log.h）。
const (
	LevelDebug = 0
	LevelInfo  = 1
	LevelWarn  = 2
	LevelError = 3
	LevelFatal = 4
)

var levelNames = [...]string{"DEBUG", "INFO", "WARN", "ERROR", "FATAL"}

// SetSink 注入统一日志 sink（fn 为 archoera_log_write 指针；nil 注销回退）。
// minLevel 低于此级别的日志直接丢弃。
func SetSink(fn unsafe.Pointer, minLevel int) {
	C.sub_log_set_ptr(fn, C.int(minLevel))
}

// SinkPtr 返回当前注入的 sink 指针（nil 表示未注入）。
func SinkPtr() unsafe.Pointer { return C.sub_log_get_sink() }

// MinLevel 返回当前最小级别。
func MinLevel() int { return int(C.sub_log_get_min()) }

// HasSink 是否已注入 sink。
func HasSink() bool { return C.sub_log_has_sink() != 0 }

// emit 是唯一的出口：有 sink 走 C.sub_log_emit（核心做二次过滤/格式化）；
// 无 sink 时回退 stderr，格式与核心一致。
func emit(level int, tag, msg string) {
	if HasSink() {
		cTag := C.CString(tag)
		cMsg := C.CString(msg)
		defer C.free(unsafe.Pointer(cTag))
		defer C.free(unsafe.Pointer(cMsg))
		C.sub_log_emit(C.int(level), cTag, cMsg)
		return
	}
	if level < MinLevel() {
		return
	}
	name := "INFO"
	if level >= 0 && level < len(levelNames) {
		name = levelNames[level]
	}
	if tag != "" {
		fmt.Fprintf(os.Stderr, "[%s %s] [%s] %s\n", time.Now().Format("15:04:05"), name, tag, msg)
	} else {
		fmt.Fprintf(os.Stderr, "[%s %s] %s\n", time.Now().Format("15:04:05"), name, msg)
	}
}

// Debug 写 DEBUG 级日志。
func Debug(tag, format string, args ...any) { emit(LevelDebug, tag, fmt.Sprintf(format, args...)) }

// Info 写 INFO 级日志。
func Info(tag, format string, args ...any) { emit(LevelInfo, tag, fmt.Sprintf(format, args...)) }

// Warn 写 WARN 级日志。
func Warn(tag, format string, args ...any) { emit(LevelWarn, tag, fmt.Sprintf(format, args...)) }

// Error 写 ERROR 级日志。
func Error(tag, format string, args ...any) { emit(LevelError, tag, fmt.Sprintf(format, args...)) }

// Fatal 写 FATAL 级日志（不退出进程；退出语义由调用方决定）。
func Fatal(tag, format string, args ...any) { emit(LevelFatal, tag, fmt.Sprintf(format, args...)) }
