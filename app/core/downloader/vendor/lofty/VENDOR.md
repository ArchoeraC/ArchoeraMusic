# vendor/lofty

上游：[`lofty`](https://crates.io/crates/lofty) 0.25.5（MIT OR Apache-2.0），
用于下载完成后的音频标签读写。

## 为什么 vendored

`lofty` 0.25.5 依赖已停止维护的 `paste` proc-macro（RUSTSEC-2024-0436）。
`paste` 只在编译期展开、不进入产物，但 `cargo audit` 会持续报 unmaintained。
上游 main 分支仍依赖 `paste`，暂无可用新版本；直接 `[patch.crates-io]` 把
`paste` 换成 `pastey` 会因包名/版本不匹配被 Cargo 忽略。

因此把 `lofty` 复制到本目录，仅做**最小改动**：

1. `Cargo.toml`：`[dependencies.paste]` → `[dependencies.pastey]`（0.2.3）；
2. `src/**`：`paste::` → `pastey::`（11 个文件）。

[`pastey`](https://crates.io/crates/pastey) 是 `paste` 的 API 兼容维护分支。
其余源码与上游 0.25.5 一致；升级时重新拉取 crate、重放上述两处改动，并跑
`cargo test --release` 后再提交。

`app/core/downloader/Cargo.toml` 用 `[patch.crates-io] lofty = { path = ... }`
强制使用本目录。
