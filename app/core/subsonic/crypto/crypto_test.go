// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

package crypto

import (
	"strings"
	"testing"

	"github.com/betastudio2/archoera-subsonic/config"
)

// 注入固定密钥（64 位 hex），避免测试触碰 dataDir/secret.key。
func setupKey(t *testing.T) {
	t.Helper()
	config.Set(config.Config{SecretKey: strings.Repeat("ab", 32)})
}

func TestEncryptDecryptRoundTrip(t *testing.T) {
	setupKey(t)
	cipher, err := EncryptString("pass1234")
	if err != nil {
		t.Fatalf("EncryptString: %v", err)
	}
	if !strings.HasPrefix(cipher, "enc:v1:") {
		t.Fatalf("密文前缀异常: %s", cipher)
	}
	plain, err := DecryptString(cipher)
	if err != nil {
		t.Fatalf("DecryptString: %v", err)
	}
	if plain != "pass1234" {
		t.Fatalf("往返不一致: %q", plain)
	}
}

// 畸形 IV（16 字节）曾导致 GCM.Open panic；必须返回错误而非崩溃。
func TestDecryptMalformedIVReturnsError(t *testing.T) {
	setupKey(t)
	bad := "enc:v1:00000000000000000000000000000000:" +
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:" +
		"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	if _, err := DecryptString(bad); err == nil {
		t.Fatalf("畸形 IV 应返回错误")
	}
}

// 非加密存量数据原样返回（向后兼容）。
func TestDecryptLegacyPlaintextPassthrough(t *testing.T) {
	setupKey(t)
	plain, err := DecryptString("plainpass")
	if err != nil || plain != "plainpass" {
		t.Fatalf("明文透传失败: %q, %v", plain, err)
	}
}
