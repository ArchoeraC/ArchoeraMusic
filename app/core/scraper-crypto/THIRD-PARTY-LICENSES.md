# 刮削器原生后端第三方许可证声明（scraper-crypto / Rust）

本目录 `app/core/scraper-crypto` 是 ArchoeraMusic 刮削器的原生后端，提供两块能力：

1. **加密**（`src/lib.rs`）：AES / RSA 模幂 / MD5 / SHA1 / 随机数，替代原先动态链接的
   系统 `OpenSSL::Crypto`；
2. **HTTP**（`src/http.rs`）：同步 `reqwest + rustls` 客户端，替代原先动态链接的
   系统 `libcurl`（发行版 libcurl 又传递依赖 libssl/libcrypto，是 OpenSSL soname
   升级打断已发布产物的最后一条路径）。

**自研代码**随本软件以 **AGPL-3.0-or-later** 授权（见 `Cargo.toml` 的 `license`
字段）；第三方 crates 按各自许可使用。

该 crate 以 `staticlib` 形式**静态合并**进 `archoera_scraper`（Rust 标准库同为
MIT OR Apache-2.0，一并静态链接），随发布产物分发，因此下列许可文本与声明需
随包提供（发布产物 `licenses/` 目录中已包含 `Apache-2.0.txt` 与 `MIT.txt`）。

## 直接依赖

| crate | 锁定版本 | 许可证 | 用途 |
|---|---|---|---|
| `aes` | 0.8.4 | MIT OR Apache-2.0 | AES-128 块加密（ECB / CBC） |
| `md-5` | 0.10.6 | MIT OR Apache-2.0 | MD5 摘要 |
| `sha1` | 0.10.7 | MIT OR Apache-2.0 | SHA1 摘要 |
| `num-bigint` | 0.4.8 | MIT OR Apache-2.0 | RSA 裸模幂 |
| `getrandom` | 0.2.17 / 0.4.3 | MIT OR Apache-2.0 | 系统随机源（Linux `getrandom` / macOS `getentropy` / Windows `BCryptGenRandom`） |
| `reqwest` | 0.13.5 | MIT OR Apache-2.0 | 同步 HTTP 客户端（`blocking` feature） |

## TLS / HTTP 栈（与 downloader 同栈，无 OpenSSL）

`reqwest`（`rustls` feature）→ `hyper-rustls` → `rustls` → `aws-lc-rs`：

| crate | 许可证 | 说明 |
|---|---|---|
| `rustls` | Apache-2.0 OR ISC OR MIT | 纯 Rust TLS，无 OpenSSL 4-Clause BSD 历史问题 |
| `aws-lc-rs` / `aws-lc-sys` | ISC AND (Apache-2.0 OR ISC) [+ Apache-2.0/MIT/BSD-3-Clause 等] | 密码学原语（BoringSSL 衍生，LICENSE 已清理），静态编译 |
| `rustls-platform-verifier` | MIT OR Apache-2.0 | 证书链校验走系统信任库（Linux OpenSSL CA 路径 / Windows CryptoAPI / macOS Keychain），语义对齐 libcurl |
| `hyper` / `h2` / `http` / `tokio` | MIT 或 MIT OR Apache-2.0 | HTTP/1.1、HTTP/2、异步运行时（blocking 客户端内部使用） |
| `flate2` / `miniz_oxide` | MIT OR Apache-2.0 / MIT OR Zlib OR Apache-2.0 | gzip / deflate 响应解压（对齐 curl 默认 `Accept-Encoding`） |

## 完整依赖清单

本 crate 的 `Cargo.lock` 共锁定 **193** 个 crate（含传递依赖与各平台条件依赖），
全部为宽松许可（MIT / Apache-2.0 / ISC / BSD / Zlib / Unicode-3.0 / 0BSD /
Unlicense / CC0 / CDLA-Permissive-2.0 等），**无 GPL / AGPL 强 copyleft 依赖**。

> 精确版本以同目录 `Cargo.lock` 为准（升级依赖时同步更新本表）。
> 例外说明：`r-efi`（仅 UEFI 目标条件依赖）声明为
> `MIT OR Apache-2.0 OR LGPL-2.1-or-later`，本项目按 **MIT** 选项使用；
> `generic-array`（RustCrypto 传递依赖）为 **MIT** 单许可，因此发布产物必须同时
> 保留 **MIT** 与 **Apache-2.0** 正文，不能只附 Apache-2.0。
>
> 需要逐项列表时可运行：
>
> ```bash
> cd app/core/scraper-crypto
> cargo metadata --format-version 1 | \
>   python3 -c 'import json,sys; [print(p["name"], p["version"], p.get("license")) \
>     for p in json.load(sys.stdin)["packages"] if p["name"] != "archoera-scraper-crypto"]'
> ```

## 合规评估（非法律意见）

上述 crates 均为 MIT / Apache-2.0 系宽松许可，与本项目 AGPL-3.0-or-later
聚合、静态链接分发兼容；不引入 GPL/AGPL 之外的 copyleft 义务。
本文档为项目维护者的合理努力评估，不构成法律意见；正式依据以上游官方许可文本为准。

## 上游与源码

- RustCrypto（`aes` / `cipher` / `digest` / `md-5` / `sha1` 等）：
  https://github.com/RustCrypto
- `num-bigint` / `num-integer` / `num-traits`：https://github.com/rust-num
- `getrandom`：https://github.com/rust-random/getrandom
- `generic-array`：https://github.com/fizyk20/generic-array
- `reqwest`：https://github.com/seanmonstar/reqwest
- `rustls`：https://github.com/rustls/rustls
- `aws-lc-rs`：https://github.com/aws/aws-lc-rs
- `hyper`：https://github.com/hyperium/hyper
- 各 crate 源码与完整许可文本也可从 https://crates.io 对应版本下载。

---
AGPL-3.0 完整文本见仓库根 `LICENSE`；第三方声明总览见根 `THIRD-PARTY-NOTICES.md`。
