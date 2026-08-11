// 安全销毁代理（FFI 导出）：宿主（Dart）销毁敏感文件前的 Go 侧协作。
//
// 为什么需要代理：Go 服务端可能持有 user.db（userPool）连接，Windows 下
// 被进程打开的文件无法覆盖/删除；代理先关闭连接再执行「随机数据覆盖写入
// N 遍 + 删除」，并**必须返回确认**（逐文件 existed/shredded/bytes/error）。
// 宿主对确认中 failed 或未覆盖的文件主动介入（Dart 核心本地销毁兜底）。
//
// 响应为 JSON：{"closedUserDb":bool,"serverRunning":bool,"results":[...]}
// 返回值语义：>=0 响应字节数；-1 请求参数错误；-2 整体处理失败（响应已含错误）。
package main

/*
#include <stdlib.h>
#include <stdint.h>
*/
import "C"

import (
	"crypto/rand"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/betastudio2/archoera-subsonic/db"
)

// shredRequest 销毁请求：文件路径列表 + 覆盖遍数（默认 3）
type shredRequest struct {
	Files  []string `json:"files"`
	Passes int      `json:"passes"`
}

// shredResult 单文件确认结果
type shredResult struct {
	Path     string `json:"path"`
	Existed  bool   `json:"existed"`
	Shredded bool   `json:"shredded"`
	Bytes    int64  `json:"bytes"`
	Error    string `json:"error,omitempty"`
}

// shredResponse 销毁确认（宿主据此决定是否核心介入兜底）
type shredResponse struct {
	// ClosedUserDb 表示已关闭 userPool 连接（销毁 user.db 前置步骤）
	ClosedUserDb bool `json:"closedUserDb"`
	// ServerRunning 表示销毁时仍有运行中的服务实例；其 user.db 已失效，
	// 宿主应重启实例重建空库
	ServerRunning bool          `json:"serverRunning"`
	Results       []shredResult `json:"results"`
}

// isUserDbFile 判断路径是否用户库或其 WAL/SHM 侧文件（销毁前需先关连接）
func isUserDbFile(path string) bool {
	base := filepath.Clean(db.DefaultUserDBPath())
	p := filepath.Clean(path)
	return p == base || strings.HasPrefix(p, base+"-wal") || strings.HasPrefix(p, base+"-shm")
}

// shredPath 覆盖删除单个文件（返回逐项确认，不 panic）
func shredPath(path string, passes int) shredResult {
	r := shredResult{Path: path}
	if passes <= 0 {
		passes = 3
	}
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return r
		}
		r.Error = err.Error()
		return r
	}
	r.Existed = true
	r.Bytes = info.Size()

	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		r.Error = err.Error()
		return r
	}
	buf := make([]byte, 64<<10) // 64KB 块
	for pass := 0; pass < passes; pass++ {
		if _, err := f.Seek(0, 0); err != nil {
			r.Error = err.Error()
			f.Close()
			return r
		}
		remaining := r.Bytes
		for remaining > 0 {
			n := int64(len(buf))
			if remaining < n {
				n = remaining
			}
			if _, err := io.ReadFull(rand.Reader, buf[:n]); err != nil {
				r.Error = err.Error()
				f.Close()
				return r
			}
			if _, err := f.Write(buf[:n]); err != nil {
				r.Error = err.Error()
				f.Close()
				return r
			}
			remaining -= n
		}
		if err := f.Sync(); err != nil {
			r.Error = err.Error()
			f.Close()
			return r
		}
	}
	f.Close()
	if err := os.Remove(path); err != nil {
		r.Error = err.Error()
		return r
	}
	r.Shredded = true
	return r
}

//export archoera_subsonic_shred_files
func archoera_subsonic_shred_files(_ C.intptr_t, reqJSON *C.char, buf *C.char, bufLen C.int) C.int {
	req := shredRequest{}
	if reqJSON != nil {
		if err := json.Unmarshal([]byte(C.GoString(reqJSON)), &req); err != nil {
			return -1
		}
	}
	if len(req.Files) == 0 {
		return -1
	}
	passes := req.Passes
	if passes <= 0 {
		passes = 3
	}

	resp := shredResponse{Results: make([]shredResult, 0, len(req.Files))}
	for _, p := range req.Files {
		// 用户库：先关连接再覆盖删除，避免进程占用导致失败
		if isUserDbFile(p) {
			db.CloseUserDB()
			resp.ClosedUserDb = true
		}
		resp.Results = append(resp.Results, shredPath(p, passes))
	}
	mu.Lock()
	resp.ServerRunning = len(states) > 0
	mu.Unlock()

	out, err := json.Marshal(resp)
	if err != nil {
		return -2
	}
	return copyToBuf(buf, bufLen, string(out))
}
