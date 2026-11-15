// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// Songloft 客户端 FFI 导出（与 Subsonic 服务端共用同一 c-shared 库）。
//
// ABI（只增不改）：
//
//	archoera_songloft_open(configJson) -> handle
//	archoera_songloft_close(handle)
//	archoera_songloft_call(handle, requestJson) -> 0 / 负数
//	archoera_songloft_take_event(handle, int *outLen) -> char*（需 free）
//	archoera_songloft_free(ptr)
//
// 事件在 Go goroutine 中产生，Dart 侧轮询 take_event；字符串由 Go 分配、
// Dart 读完调用 free，避免 4KB 定长缓冲截断目录列表。
package main

/*
#include <stdlib.h>
#include <stdint.h>
*/
import "C"

import (
	"encoding/json"
	"sync"
	"unsafe"

	"github.com/betastudio2/archoera-subsonic/songloft"
)

var (
	slMu     sync.Mutex
	slNext   int64 = 1
	slStates       = map[int64]*songloft.Session{}
)

//export archoera_songloft_open
func archoera_songloft_open(configJSON *C.char) C.intptr_t {
	if configJSON == nil {
		return 0
	}
	var cfg songloft.Config
	if err := json.Unmarshal([]byte(C.GoString(configJSON)), &cfg); err != nil {
		return 0
	}
	sess, err := songloft.Open(cfg)
	if err != nil {
		return 0
	}
	slMu.Lock()
	id := slNext
	slNext++
	slStates[id] = sess
	slMu.Unlock()
	return C.intptr_t(id)
}

//export archoera_songloft_close
func archoera_songloft_close(h C.intptr_t) {
	slMu.Lock()
	sess, ok := slStates[int64(h)]
	if ok {
		delete(slStates, int64(h))
	}
	slMu.Unlock()
	if ok {
		sess.Close()
	}
}

//export archoera_songloft_call
func archoera_songloft_call(h C.intptr_t, requestJSON *C.char) C.int {
	if requestJSON == nil {
		return -1
	}
	slMu.Lock()
	sess, ok := slStates[int64(h)]
	slMu.Unlock()
	if !ok {
		return -1
	}
	var req struct {
		ID     string          `json:"id"`
		Method string          `json:"method"`
		Params json.RawMessage `json:"params"`
	}
	if err := json.Unmarshal([]byte(C.GoString(requestJSON)), &req); err != nil {
		return -1
	}
	if req.Method == "" {
		return -1
	}
	if err := sess.Call(req.ID, req.Method, req.Params); err != nil {
		return -2
	}
	return 0
}

//export archoera_songloft_take_event
func archoera_songloft_take_event(h C.intptr_t, outLen *C.int) *C.char {
	if outLen == nil {
		return nil
	}
	*outLen = 0
	slMu.Lock()
	sess, ok := slStates[int64(h)]
	slMu.Unlock()
	if !ok {
		return nil
	}
	select {
	case ev := <-sess.Events():
		*outLen = C.int(len(ev))
		return C.CString(string(ev))
	default:
		return nil
	}
}

//export archoera_songloft_free
func archoera_songloft_free(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}
