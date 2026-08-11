package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/betastudio2/archoera-subsonic/config"
)

// 兼容 TS 层 encryptString/decryptString 的 AES-256-GCM 解密
// 密文格式: enc:v1:<iv_hex>:<tag_hex>:<ct_hex>

const prefix = "enc:v1:"

var cachedKey []byte

// LoadKey 从配置（secretKey hex）或 secret.key 文件加载 32 字节密钥；
// 两者都没有时自动生成并持久化到 dataDir/secret.key（首次启动自举，
// 后续每次运行复用同一密钥，已加密的用户密文可跨重启解密）。
func LoadKey() ([]byte, error) {
	if cachedKey != nil {
		return cachedKey, nil
	}

	// 1. 配置密钥优先（hex 编码，Dart 宿主经 create 注入）
	if key := config.SecretKey(); key != "" {
		if len(key) == 64 {
			decoded, err := hex.DecodeString(key)
			if err == nil {
				cachedKey = decoded
				return decoded, nil
			}
		}
		return nil, fmt.Errorf("secretKey must be 64-char hex")
	}

	// 2. 密钥文件（持久化：每次启动复用同一密钥，用户密文可跨重启解密）
	keyPath := secretKeyPath()
	raw, err := os.ReadFile(keyPath)
	if err == nil {
		if len(raw) != 32 {
			return nil, fmt.Errorf("secret.key length %d, expected 32", len(raw))
		}
		cachedKey = raw
		return raw, nil
	}
	if !os.IsNotExist(err) {
		return nil, fmt.Errorf("read secret.key: %w", err)
	}

	// 3. 无配置也无文件：自动生成并持久化（自举）
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, fmt.Errorf("generate key: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(keyPath), 0o700); err != nil {
		return nil, fmt.Errorf("mkdir secret key dir: %w", err)
	}
	if err := os.WriteFile(keyPath, key, 0o600); err != nil {
		return nil, fmt.Errorf("write secret.key: %w", err)
	}
	cachedKey = key
	return key, nil
}

// secretKeyPath 数据目录下的密钥文件路径（dataDir 空时回退 ./data）。
func secretKeyPath() string {
	dataDir := config.DataDir()
	if dataDir == "" {
		wd, err := os.Getwd()
		if err != nil {
			dataDir = filepath.Join(".", "data")
		} else {
			dataDir = filepath.Join(wd, "data")
		}
	}
	return filepath.Join(dataDir, "secret.key")
}

// DecryptString 解密 enc:v1:<iv>:<tag>:<ct> 格式的密文
// 非加密格式（明文存量数据）原样返回（向后兼容）
func DecryptString(ciphertext string) (string, error) {
	if ciphertext == "" {
		return "", nil
	}
	if !strings.HasPrefix(ciphertext, prefix) {
		// 明文存量数据
		return ciphertext, nil
	}

	rest := ciphertext[len(prefix):]
	parts := strings.SplitN(rest, ":", 3)
	if len(parts) != 3 {
		return "", fmt.Errorf("invalid ciphertext format")
	}

	iv, err := hex.DecodeString(parts[0])
	if err != nil {
		return "", fmt.Errorf("decode iv: %w", err)
	}
	tag, err := hex.DecodeString(parts[1])
	if err != nil {
		return "", fmt.Errorf("decode tag: %w", err)
	}
	ct, err := hex.DecodeString(parts[2])
	if err != nil {
		return "", fmt.Errorf("decode ct: %w", err)
	}

	key, err := LoadKey()
	if err != nil {
		return "", err
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}

	// Go GCM expects tag appended to ciphertext
	combined := append(ct, tag...)
	plaintext, err := gcm.Open(nil, iv, combined, nil)
	if err != nil {
		return "", fmt.Errorf("decrypt: %w", err)
	}
	return string(plaintext), nil
}

// EncryptString 加密字符串，格式与 TS encryptString 一致：enc:v1:<iv>:<tag>:<ct>
// 空串原样返回（与 TS 一致）
func EncryptString(plaintext string) (string, error) {
	if plaintext == "" {
		return "", nil
	}
	key, err := LoadKey()
	if err != nil {
		return "", err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	iv := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(iv); err != nil {
		return "", fmt.Errorf("rand: %w", err)
	}
	sealed := gcm.Seal(nil, iv, []byte(plaintext), nil)
	ct := sealed[:len(sealed)-gcm.Overhead()]
	tag := sealed[len(sealed)-gcm.Overhead():]
	return fmt.Sprintf("%s%s:%s:%s", prefix, hex.EncodeToString(iv), hex.EncodeToString(tag), hex.EncodeToString(ct)), nil
}
