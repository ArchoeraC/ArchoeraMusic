# Subsonic Go 后端第三方许可证声明

本目录 `app/core/subsonic` 为 ArchoeraMusic 的 Subsonic 兼容 Go 后端，
其自研代码随本软件以 AGPL-3.0 授权，第三方组件按各自许可使用（逐项登记见下）。

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

## 合规评估（非法律意见）

全部直接/间接依赖为 MIT / BSD-3-Clause 宽松许可，在各自条款下可与本模块 AGPL-3.0 代码共存。
本文档为项目维护者的合理努力评估，不构成法律意见；正式依据以上游官方许可文本为准。

---
AGPL-3.0 完整文本见仓库根 `LICENSE`；第三方声明总览见根 `THIRD-PARTY-NOTICES.md`。
