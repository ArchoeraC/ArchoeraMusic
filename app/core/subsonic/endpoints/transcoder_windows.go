//go:build windows

package endpoints

// 转码器动态库加载（Windows：LoadLibrary/GetProcAddress）
// 与 transcoder_unix.go 提供相同的 Go 层 API：
//   openTranscoder / closeTranscoder / callTranscode
//
// 注意：Windows 上服务端 DLL（mingw 构建）与转码器 DLL（Rust MSVC cdylib）
// 通过系统 ABI 互操作，句柄为 HMODULE。

/*
#include <windows.h>
#include <stdlib.h>
typedef int (*archoera_transcode_fn)(const char*, const char*, int, int, int, int);
static void* archoera_dlopen(const char* path) { return (void*)LoadLibraryA(path); }
static int archoera_dlclose(void* h) { return FreeLibrary((HMODULE)h) ? 0 : -1; }
static int archoera_call_transcode(void* h, const char* in, const char* out, int br, int sr, int ch, int skip) {
    archoera_transcode_fn fn = (archoera_transcode_fn)(void*)GetProcAddress((HMODULE)h, "archoera_transcode_mp3");
    if (!fn) return -100;
    return fn(in, out, br, sr, ch, skip);
}
*/
import "C"

import "unsafe"

// openTranscoder 打开转码器动态库，失败返回 nil
func openTranscoder(path string) unsafe.Pointer {
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))
	return C.archoera_dlopen(cPath)
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
