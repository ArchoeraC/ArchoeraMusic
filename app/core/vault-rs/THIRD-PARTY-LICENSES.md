# vault-rs 第三方许可证声明（archoera-vault）

本目录 `app/core/vault-rs` 为 ArchoeraMusic 的凭据保险库（Rust 重实现，
与历史 C# 版字节兼容）。自研代码随本软件以 **AGPL-3.0** 授权；第三方 crate
按各自许可使用，均为 **MIT / Apache-2.0 / BSD** 系，与 AGPL-3.0 兼容。

## 运行时依赖

| 组件 | 版本 | 许可证 | 说明 |
|---|---|---|---|
| `argon2` | 0.5 | **MIT / Apache-2.0** | 口令派生（Argon2id；`default-features=false`，纯 Rust） |
| `aes-gcm` | 0.10 | **MIT / Apache-2.0** | 记录加解密（AES-256-GCM） |
| `hkdf` | 0.12 | **MIT / Apache-2.0** | 子密钥派生 |
| `sha2` | 0.10 | **MIT / Apache-2.0** | SHA-256 / HMAC 摘要原语 |
| `hmac` | 0.12 | **MIT / Apache-2.0** | 消息认证码 |
| `subtle` | 2 | **BSD-3-Clause** | 常数时间比较 |
| `zeroize` | 1 | **MIT / Apache-2.0** | 敏感缓冲区清零 |
| `getrandom` | 0.2 | **MIT / Apache-2.0** | 系统安全随机源 |
| `base64` | 0.22 | **MIT / Apache-2.0** | 编码 |
| `libc` | 0.2 | **MIT / Apache-2.0** | 平台内存锁（`mlock`） |

## 平台专属依赖（按目标平台编译）

| 组件 | 平台 | 许可证 | 说明 |
|---|---|---|---|
| `windows` | Windows | **MIT / Apache-2.0** | DPAPI、进程护栏、内存锁 |
| `security-framework` | macOS | **MIT / Apache-2.0** | Keychain 通用密码 |

## 构建期依赖

| 组件 | 许可证 | 说明 |
|---|---|---|
| `winres` | **MIT** | Windows VERSIONINFO / 图标资源（非 Windows 目标跳过） |

> 加密原语均来自 RustCrypto 官方 crate，未内嵌 OpenSSL / libsodium 等原生库；
> 各许可正文随仓库与发布包 `licenses/` 分发。本表不构成法律意见。
