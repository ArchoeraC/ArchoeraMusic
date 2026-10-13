// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

package credentials

import "testing"

func TestSetGetDeleteClear(t *testing.T) {
	Clear()
	t.Cleanup(Clear)

	if _, ok := Get("alice"); ok {
		t.Fatalf("空表不应命中 alice")
	}
	Set("alice", "secret")
	if pw, ok := Get("alice"); !ok || pw != "secret" {
		t.Fatalf("Set/Get 失败: pw=%q ok=%v", pw, ok)
	}
	// 覆盖：旧值尽量清零，新值生效
	Set("alice", "newsecret")
	if pw, ok := Get("alice"); !ok || pw != "newsecret" {
		t.Fatalf("覆盖后 Get 失败: pw=%q ok=%v", pw, ok)
	}
	Delete("alice")
	if _, ok := Get("alice"); ok {
		t.Fatalf("Delete 后仍命中 alice")
	}
}

func TestReplaceAll(t *testing.T) {
	Clear()
	t.Cleanup(Clear)

	Set("stale", "old")
	ReplaceAll(map[string]string{"bob": "pw1", "carol": "pw2"})
	if _, ok := Get("stale"); ok {
		t.Fatalf("ReplaceAll 未清空旧条目")
	}
	if pw, ok := Get("bob"); !ok || pw != "pw1" {
		t.Fatalf("ReplaceAll 后 bob 失败: pw=%q ok=%v", pw, ok)
	}
	if pw, ok := Get("carol"); !ok || pw != "pw2" {
		t.Fatalf("ReplaceAll 后 carol 失败: pw=%q ok=%v", pw, ok)
	}

	// nil 等价清空
	ReplaceAll(nil)
	if _, ok := Get("bob"); ok {
		t.Fatalf("ReplaceAll(nil) 未清空")
	}

	// 空映射等价清空
	ReplaceAll(map[string]string{})
	if _, ok := Get("carol"); ok {
		t.Fatalf("ReplaceAll(空映射) 未清空")
	}
}
