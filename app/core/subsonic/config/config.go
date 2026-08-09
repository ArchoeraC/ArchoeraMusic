// 运行期配置 + 宿主（Dart）桥接
//
// 原为环境变量 + HTTP 回调 TS（Node.js），FFI 化后改为：
//   - 配置由 lib 入口 archoera_subsonic_create 一次性注入（config.Set）
//   - 事件（started/error/lyric-request/scan-request）经 SetEventSink 发往宿主
//   - 在线歌词注入：RequestOnlineLyrics 发事件并同步等待，宿主经 RespondLyric 提交结果
//     （避免跨线程同步回调 Dart，符合 Dart VM 对阻塞 FFI 线程的中断信号限制）
package config

import (
	"encoding/json"
	"sync"
	"time"
)

// Config 运行期配置（与 Dart 侧 SubsonicConfig 对齐）
type Config struct {
	DBPath     string `json:"dbPath"`
	MusicDir   string `json:"musicDir"`
	DataDir    string `json:"dataDir"`
	SecretKey  string `json:"secretKey"`
	Addr       string `json:"addr"`
	Transcoder string `json:"transcoder"`
}

var (
	cfgMu   sync.RWMutex
	current Config
)

// Set 由 lib 入口 create() 调用
func Set(c Config) {
	cfgMu.Lock()
	current = c
	cfgMu.Unlock()
}

// Get 返回当前配置
func Get() Config {
	cfgMu.RLock()
	defer cfgMu.RUnlock()
	return current
}

// DBPath 数据库路径
func DBPath() string { return Get().DBPath }

// MusicDir 音乐根目录
func MusicDir() string { return Get().MusicDir }

// DataDir 数据目录
func DataDir() string { return Get().DataDir }

// SecretKey 凭据加密密钥（hex）
func SecretKey() string { return Get().SecretKey }

// Addr 监听地址
func Addr() string { return Get().Addr }

// Transcoder 转码器动态库路径
func Transcoder() string { return Get().Transcoder }

/* ------------------------------------------------------------------ */
/* 事件总线（Go → 宿主）                                                */
/* ------------------------------------------------------------------ */

var (
	eventMu   sync.RWMutex
	eventSink func(string)
)

// SetEventSink 注册事件发送器（lib 入口 create 时注入实例 channel）
func SetEventSink(fn func(string)) {
	eventMu.Lock()
	eventSink = fn
	eventMu.Unlock()
}

// EmitEvent 发送事件（channel 满时丢弃，非阻塞）
func EmitEvent(s string) {
	eventMu.RLock()
	fn := eventSink
	eventMu.RUnlock()
	if fn != nil {
		fn(s)
	}
}

/* ------------------------------------------------------------------ */
/* 在线歌词注入（事件 + 异步响应）                                       */
/* ------------------------------------------------------------------ */

type lyricWaiter struct {
	ch chan string
}

var (
	lyricMu       sync.Mutex
	lyricNextID   int64
	lyricWaiters  = map[int64]*lyricWaiter{}
	lyricWaitTime = 8 * time.Second
)

// RequestOnlineLyrics 请求宿主（Dart）查询在线歌词，同步等待结果
// 返回歌词注入 JSON（endpoints.injectLyricResp 结构），超时或无宿主返回 ""
func RequestOnlineLyrics(songID, title, artist string) string {
	eventMu.RLock()
	hasSink := eventSink != nil
	eventMu.RUnlock()
	if !hasSink {
		return ""
	}

	lyricMu.Lock()
	lyricNextID++
	id := lyricNextID
	lyricWaiters[id] = &lyricWaiter{ch: make(chan string, 1)}
	lyricMu.Unlock()

	req, _ := json.Marshal(map[string]any{
		"type":   "lyric-request",
		"id":     id,
		"songId": songID,
		"title":  title,
		"artist": artist,
	})
	EmitEvent(string(req))

	select {
	case res := <-lyricWaiters[id].ch:
		return res
	case <-time.After(lyricWaitTime):
		lyricMu.Lock()
		delete(lyricWaiters, id)
		lyricMu.Unlock()
		return ""
	}
}

// RespondLyric 宿主（Dart）提交歌词查询结果
func RespondLyric(requestID int64, resultJSON string) {
	lyricMu.Lock()
	w, ok := lyricWaiters[requestID]
	if ok {
		delete(lyricWaiters, requestID)
	}
	lyricMu.Unlock()
	if ok {
		w.ch <- resultJSON
	}
}
