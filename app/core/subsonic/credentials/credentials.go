// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// Package credentials 维护 Subsonic 用户凭据的内存表（明文，仅进程生命周期内）。
//
// 背景（SEC-01）：用户密码不再以 dataDir/secret.key 的字段级加密作为唯一
// 保护，而是由宿主（Dart）经 FFI 注入——密码持久化统一走凭据保险库
//（vault，uid=`subsonic:<username>`）。本表仅存在于进程内存，服务端认证
// 优先查表；未命中时才回退到旧 user.db 密文解密路径（standalone/Docker 与
// 未迁移旧库兼容）。
//
// 清零说明：Go 字符串不可变且由 GC 管理，无法保证可靠擦除；本包按 []byte
// 存储，并在替换/删除时对旧缓冲尽力写零（best-effort，不构成安全保证——
// 编译器优化 / GC 复制仍可能留存副本）。
package credentials

import "sync"

var (
	mu    sync.RWMutex
	table = map[string][]byte{}
)

// ReplaceAll 用给定映射全量替换凭据表（清空旧表并尽力清零旧值）。
// 传入 nil 等价于清空。由 FFI `archoera_subsonic_set_credentials` 调用。
func ReplaceAll(m map[string]string) {
	mu.Lock()
	defer mu.Unlock()
	zeroAll(table)
	table = make(map[string][]byte, len(m))
	for user, pass := range m {
		table[user] = []byte(pass)
	}
}

// Set 写入/覆盖单个用户密码（替换旧值时尽力清零）。
func Set(user, pass string) {
	mu.Lock()
	defer mu.Unlock()
	if old, ok := table[user]; ok {
		zero(old)
	}
	table[user] = []byte(pass)
}

// Get 读取单个用户密码明文；不存在返回 ("", false)。
// 注意：返回的 string 是缓冲副本，调用方无法擦除，用后即弃。
func Get(user string) (string, bool) {
	mu.RLock()
	defer mu.RUnlock()
	b, ok := table[user]
	if !ok {
		return "", false
	}
	return string(b), true
}

// Delete 删除单个用户密码（尽力清零旧值）。
func Delete(user string) {
	mu.Lock()
	defer mu.Unlock()
	if old, ok := table[user]; ok {
		zero(old)
		delete(table, user)
	}
}

// Clear 清空整个凭据表（尽力清零全部旧值）。
func Clear() {
	mu.Lock()
	defer mu.Unlock()
	zeroAll(table)
	table = map[string][]byte{}
}

// zero 尽力清零给定缓冲。
func zero(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

// zeroAll 尽力清零表中全部缓冲。
func zeroAll(t map[string][]byte) {
	for _, b := range t {
		zero(b)
	}
}
