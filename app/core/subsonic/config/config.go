// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 运行期配置 + 宿主（Dart）桥接
//
// 原为环境变量 + HTTP 回调 TS（Node.js），FFI 化后改为：
//   - 配置由 lib 入口 archoera_subsonic_create 一次性注入（config.Set）
//   - 事件（started/error/scan-request）经 SetEventSink 发往宿主
//
// 歌词不作为事件：服务端只读取曲库内嵌歌词，在线歌词交由客户端处理。
package config

import (
	"sync"
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
