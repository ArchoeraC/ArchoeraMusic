// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//go:build !windows

package endpoints

// 转码器动态库加载（非 Windows 平台：dlopen/dlsym）
// 与 transcoder_windows.go 提供相同的 Go 层 API：
//   openTranscoder / closeTranscoder / callTranscode
//
// Windows 版见 transcoder_windows.go（LoadLibrary/GetProcAddress）。

/*
#cgo LDFLAGS: -ldl
#include <dlfcn.h>
#include <stdlib.h>
typedef int (*archoera_transcode_fn)(const char*, const char*, int, int, int, int);
typedef void (*archoera_set_log_sink_fn)(void*, int);
static void* archoera_dlopen(const char* path) { return dlopen(path, RTLD_NOW); }
static int archoera_dlclose(void* h) { return dlclose(h); }
static int archoera_call_transcode(void* h, const char* in, const char* out, int br, int sr, int ch, int skip) {
    archoera_transcode_fn fn = (archoera_transcode_fn)dlsym(h, "archoera_transcode_mp3");
    if (!fn) return -100;
    return fn(in, out, br, sr, ch, skip);
}
// 解析并转发统一日志 sink（转码器符号缺失时返回 -100，静默跳过）。
static int archoera_apply_log_sink(void* h, void* sink, int min) {
    archoera_set_log_sink_fn fn = (archoera_set_log_sink_fn)dlsym(h, "archoera_transcoder_set_log_sink");
    if (!fn) return -100;
    fn(sink, min);
    return 0;
}
*/
import "C"

import (
	"unsafe"

	"github.com/betastudio2/archoera-subsonic/logging"
)

// openTranscoder 打开转码器动态库，失败返回 nil
func openTranscoder(path string) unsafe.Pointer {
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))
	h := C.archoera_dlopen(cPath)
	if h != nil {
		// 统一日志：把本进程 Go 侧保存的 sink 指针转发给转码器
		//（转码器经 dlopen 在同进程内运行，可直接回调 archoera_log_write）。
		C.archoera_apply_log_sink(h, logging.SinkPtr(), C.int(logging.MinLevel()))
	}
	return h
}

// closeTranscoder 关闭转码器句柄
func closeTranscoder(h unsafe.Pointer) {
	if h != nil {
		C.archoera_dlclose(h)
	}
}

// callTranscode 调用 archoera_transcode_mp3；返回 0 表示成功
func callTranscode(h unsafe.Pointer, inPath, outPath string, bitrate, sampleRate, channels, skip int) int {
	cIn := C.CString(inPath)
	defer C.free(unsafe.Pointer(cIn))
	cOut := C.CString(outPath)
	defer C.free(unsafe.Pointer(cOut))
	return int(C.archoera_call_transcode(h, cIn, cOut,
		C.int(bitrate), C.int(sampleRate), C.int(channels), C.int(skip)))
}
