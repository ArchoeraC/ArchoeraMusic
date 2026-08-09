# Subsonic Go 后端第三方许可证声明

本目录 `server/subsonic` 为 SPlayer-Next 服务端的 Subsonic 兼容 Go 后端，
随本软件以 AGPL-3.0 授权。以下为其 Go 模块依赖的许可证摘要。

## 直接依赖

| 组件 | 版本 | 许可证 | 说明 |
|---|---|---|---|
| `github.com/go-chi/chi/v5` | v5.2.1 | MIT | 轻量 HTTP 路由 |
| `github.com/google/uuid` | v1.6.0 | BSD-3-Clause | UUID 生成 |
| `golang.org/x/image` | v0.18.0 | BSD-3-Clause | 图像处理原语 |
| `modernc.org/sqlite` | v1.34.5 | BSD-3-Clause | 纯 Go SQLite 实现（无 cgo） |

## 间接依赖（均为 MIT / BSD-3-Clause）

| 组件 | 版本 | 许可证 |
|---|---|---|
| `github.com/dustin/go-humanize` | v1.0.1 | MIT |
| `github.com/mattn/go-isatty` | v0.0.20 | MIT |
| `github.com/ncruces/go-strftime` | v0.1.9 | MIT |
| `github.com/remyoudompheng/bigfft` | v0.0.0-... | BSD-3-Clause |
| `golang.org/x/exp` | v0.0.0-... | BSD-3-Clause |
| `golang.org/x/sys` | v0.30.0 | BSD-3-Clause |
| `modernc.org/libc` | v1.61.6 | BSD-3-Clause |
| `modernc.org/mathutil` | v1.7.1 | BSD-3-Clause |
| `modernc.org/memory` | v1.8.1 | BSD-3-Clause |

## 许可兼容性结论

全部依赖为 MIT 或 BSD-3-Clause，与 AGPL-3.0 完全兼容，无 copyleft 冲突。

---
AGPL-3.0 完整文本见仓库根 `LICENSE`；第三方声明总览见根 `THIRD-PARTY-NOTICES.md`。
