// Archoera Subsonic 服务端 FFI 库入口（c-shared）
//
// 原为 CLI（main() + 环境变量 + spawn 转码器子进程 + HTTP 回调 Node.js TS）。
// FFI 化（Dart 直连）：
//   - create 异步启动 http server（监听端口供外部 Subsonic 客户端连接，服务端=发送方）
//   - 事件（started/error/lyric-request/scan-request）经 poll_event 拉取
//   - 在线歌词注入：事件 + archoera_subsonic_lyric_response 异步响应（见 config 包说明）
//   - 凭据加解密导出给 Dart 管理层（格式与 TS encryptString 兼容）
package main

/*
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"sync"
	"time"
	"unsafe"

	"github.com/betastudio2/archoera-subsonic/config"
	"github.com/betastudio2/archoera-subsonic/crypto"
	"github.com/betastudio2/archoera-subsonic/db"
	"github.com/betastudio2/archoera-subsonic/middleware"
	"github.com/go-chi/chi/v5"
)

// serverState 单个服务实例状态
type serverState struct {
	srv    *http.Server
	events chan string
	done   chan struct{}
}

var (
	mu     sync.Mutex
	nextID int64 = 1
	states       = map[int64]*serverState{}
)

// copyToBuf 将 Go 字符串写入 C 缓冲区（含结尾 \0），返回写入字节数（不含 \0）
func copyToBuf(buf *C.char, bufLen C.int, s string) C.int {
	if buf == nil || bufLen <= 0 {
		return C.int(len(s))
	}
	n := len(s)
	if n >= int(bufLen) {
		n = int(bufLen) - 1
	}
	dst := unsafe.Slice((*byte)(unsafe.Pointer(buf)), n+1)
	copy(dst[:n], s[:n])
	dst[n] = 0
	return C.int(n)
}

//export archoera_subsonic_create
func archoera_subsonic_create(configJSON *C.char) C.intptr_t {
	cfg := config.Config{}
	if configJSON != nil {
		_ = json.Unmarshal([]byte(C.GoString(configJSON)), &cfg)
	}
	if cfg.Addr == "" {
		// 默认监听全接口：Go 对 "0.0.0.0:0" 生成双栈监听（IPv4+IPv6），
		// 客户端可用 localhost / 局域网 IP / 真实 IPv4 / IPv6 连接。
		// 端口 0 = 系统分配空闲端口，实际地址经 started 事件回传。
		// 需要限制访问面时由宿主经 config.Addr 指定（如 "127.0.0.1:0"）。
		cfg.Addr = "0.0.0.0:0"
	}

	mu.Lock()
	id := nextID
	nextID++
	mu.Unlock()

	st := &serverState{
		events: make(chan string, 256),
		done:   make(chan struct{}),
	}

	go func() {
		if err := runServer(st, cfg); err != nil {
			st.events <- fmt.Sprintf(`{"type":"error","message":%q}`, err.Error())
		}
		close(st.done)
	}()

	mu.Lock()
	states[id] = st
	mu.Unlock()
	return C.intptr_t(id)
}

// runServer 在 goroutine 内运行服务器（不在 Dart 调用线程上长跑，规避 Dart VM 中断信号）
func runServer(st *serverState, cfg config.Config) error {
	if cfg.DBPath == "" {
		cfg.DBPath = db.DefaultDBPath()
	}
	// 先注入配置：OpenUserDB/DefaultUserDBPath 依赖 DataDir 推导用户库路径
	config.Set(cfg)
	if err := db.Open(cfg.DBPath); err != nil {
		return fmt.Errorf("打开数据库失败 %s: %w", cfg.DBPath, err)
	}
	defer db.Close()
	// 独立用户库（subsonic_* 用户数据）：先开库再建表（EnsureTables 同时建媒体库与用户库表）
	if err := db.OpenUserDB(db.DefaultUserDBPath()); err != nil {
		return fmt.Errorf("打开用户数据库失败: %w", err)
	}
	if err := db.EnsureTables(); err != nil {
		return fmt.Errorf("初始化表结构失败: %w", err)
	}
	// 自动迁移：library.db 中遗留的旧 subsonic_* 数据 → user.db（幂等）
	if err := db.MigrateUserDB(); err != nil {
		return fmt.Errorf("迁移用户数据失败: %w", err)
	}

	config.SetEventSink(func(s string) {
		select {
		case st.events <- s:
		default:
			// channel 满则丢弃（宿主轮询不及时时的保护）
		}
	})

	// 自举凭据密钥：未注入 secretKey 时生成并持久化到 dataDir/secret.key
	//（启动即生成，而非首次加密时惰性生成，保证密钥协商从 started 起已就绪）
	if _, err := crypto.LoadKey(); err != nil {
		return fmt.Errorf("初始化凭据密钥失败: %w", err)
	}

	if dedupCount, err := db.RemoveDuplicatePaths(); err != nil {
		log.Printf("[subsonic] 路径去重失败: %v", err)
	} else if dedupCount > 0 {
		log.Printf("[subsonic] 路径去重: 清理 %d 条重复行", dedupCount)
	}

	r := chi.NewRouter()
	r.Use(middleware.Authenticate)
	r.Handle("/*", http.HandlerFunc(dispatch))

	// 端口 0（或空）→ 系统分配空闲端口；实际地址经 started 事件回传，
	// Dart 宿主据此构造客户端 URL，避免硬编码固定端口。
	ln, err := net.Listen("tcp", cfg.Addr)
	if err != nil {
		return fmt.Errorf("监听 %s 失败: %w", cfg.Addr, err)
	}
	actual := ln.Addr().String()
	st.srv = &http.Server{Addr: actual, Handler: r}
	st.events <- fmt.Sprintf(`{"type":"started","addr":%q,"dbPath":%q}`, actual, cfg.DBPath)
	log.Printf("[subsonic] Subsonic API 监听 %s", actual)
	if err := st.srv.Serve(ln); err != nil && err != http.ErrServerClosed {
		return err
	}
	log.Printf("[subsonic] 已安全退出")
	return nil
}

//export archoera_subsonic_poll_event
func archoera_subsonic_poll_event(h C.intptr_t, buf *C.char, bufLen C.int) C.int {
	mu.Lock()
	st, ok := states[int64(h)]
	mu.Unlock()
	if !ok {
		return -1
	}
	select {
	case ev := <-st.events:
		return copyToBuf(buf, bufLen, ev)
	default:
		return 0
	}
}

//export archoera_subsonic_destroy
func archoera_subsonic_destroy(h C.intptr_t) {
	mu.Lock()
	st, ok := states[int64(h)]
	delete(states, int64(h))
	mu.Unlock()
	if !ok {
		return
	}
	config.SetEventSink(nil)
	if st.srv != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = st.srv.Shutdown(ctx)
	}
	<-st.done
}

//export archoera_subsonic_lyric_response
func archoera_subsonic_lyric_response(_ C.intptr_t, requestID C.long, resultJSON *C.char) {
	res := ""
	if resultJSON != nil {
		res = C.GoString(resultJSON)
	}
	config.RespondLyric(int64(requestID), res)
}

//export archoera_subsonic_encrypt
func archoera_subsonic_encrypt(_ C.intptr_t, plain *C.char, buf *C.char, bufLen C.int) C.int {
	if plain == nil || buf == nil {
		return -1
	}
	out, err := crypto.EncryptString(C.GoString(plain))
	if err != nil {
		return -2
	}
	return copyToBuf(buf, bufLen, out)
}

//export archoera_subsonic_decrypt
func archoera_subsonic_decrypt(_ C.intptr_t, cipher *C.char, buf *C.char, bufLen C.int) C.int {
	if cipher == nil || buf == nil {
		return -1
	}
	out, err := crypto.DecryptString(C.GoString(cipher))
	if err != nil {
		return -2
	}
	return copyToBuf(buf, bufLen, out)
}

// 注意：c-shared 构建需要的空 main() 在 main_ffi.go（!standalone tag），
// standalone（Docker）入口见 standalone.go（standalone tag）。
