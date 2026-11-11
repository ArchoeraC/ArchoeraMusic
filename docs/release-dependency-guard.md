# 发布依赖门禁（Linux）

> 目标：发版产物**不因发行版升级系统库（soname/ABI 变化）而无法启动**。
> 本文说明依赖策略、两道自动门禁与新增依赖时的决策流程。

## 1. 背景

Linux 二进制通过「运行时按 soname 查找共享库」加载依赖。发行版升级可能改变 soname
或符号版本，历史上已经踩过：

- FFmpeg `libavformat.so.60 → .63`、TagLib `libtag.so.1 → .2`（因此引擎/scraper
  改为按发行版分别构建 + 内嵌运行库）；
- OpenSSL `libcrypto.so.3 → .4`（Arch 升级预告）：scraper 的加密与 HTTP 均已
  改为内嵌 Rust staticlib（AES/RSA + `reqwest/rustls`），scanner 曲目 id 改为
  纯托管 MD5，产物不再直接或间接依赖 `libssl/libcrypto`。

`ldd` 在构建机能跑通，并不代表用户机器能跑通——构建机恰好有同名库时，缺失的
`$ORIGIN`/RUNPATH 会被系统库静默顶替。因此需要**静态依赖守卫 + 真实启动冒烟**。

## 2. 依赖策略

按优先级：

1. **能去掉就去掉**：窄功能优先用纯 Rust / 纯托管实现，避免引入系统 ABI 依赖
   （例：scraper 加密、scanner MD5）。
2. **发行版敏感库内嵌**：与 `bundle-linux-runtime.sh` 一致，FFmpeg / TagLib / opus
   等收进 `native/`，并把 `native/`、`lib/` 下 ELF 的 RUNPATH 归一化为 `$ORIGIN`。
   闭包收拢只沿**直接 DT_NEEDED** 遍历，遇到系统库（`DENY_RE`）立即停止——不能
   用 `ldd` 的全量传递闭包，否则会把系统 `libcurl` 的 TLS/HTTP 栈
   （`libssl/libcrypto/libssh2/nghttp2/ngtcp2/krb5…`）整棵拖进产物。
3. **只有 ABI 稳定的库才允许由系统提供**：当前允许清单见
   `app/tool/check_bundle_deps.sh` 的 `ALLOW_RE`（glibc/GCC runtime、GTK3 栈、
   X11/Wayland、`libdbus-1`、`libsqlite3` 等）。这些同时在打包 `depends` 中声明。
4. **禁止直接依赖 `libssl` / `libcrypto`**。产物中已不存在任何 OpenSSL 使用
   路径：scraper 的加密（Rust staticlib）与 HTTP（`reqwest + rustls`）均静态
   链接；`archoera_scraper` 的 CMake 在链接后调用
   `cmake/check_http_deps.cmake`，一旦重新引入 `libcurl/libssl/libcrypto`
   会在构建期直接失败。

## 3. 两道门禁

### 3.1 静态依赖守卫

```bash
bash app/tool/check_bundle_deps.sh <bundle>
```

逐 ELF 检查：

- 每个 `DT_NEEDED` 要么已在 bundle 内（`native/`、`lib/`、同目录），要么命中系统
  允许清单；未登记的系统依赖直接失败；
- 已内嵌的库必须**实际解析到 bundle 内**（`ldd` 按产物自身 RUNPATH 解析，不借助
  `LD_LIBRARY_PATH`），防止 `$ORIGIN` 丢失后被构建机系统库顶替；
- 内嵌库 `SONAME` 与需求名一致；
- `RUNPATH` 只允许 `$ORIGIN...`，防止构建机绝对路径进入产物；
- 禁止 `libssl/libcrypto`；
- NativeAOT 的 dlopen 伴随库（`libe_sqlite3.so`）与关键可执行文件齐全。

通过后在 bundle 根写入 `ARCHOERA-DEPENDENCIES.txt`（系统/内嵌清单，随包分发）。

### 3.2 启动冒烟

```bash
bash app/tool/smoke_start_linux.sh <bundle>
```

在临时 `HOME` / `XDG_*` + Xvfb 虚拟显示下真实拉起 `archoera_music`：

- `LD_BIND_NOW=1`：启动阶段立即解析全部动态符号，缺库/缺符号立刻失败；
- 要求进程进入事件循环并存活 `ARCHOERA_SMOKE_SECONDS`（默认 15s）；
- 命中 `error while loading shared libraries` / `cannot open shared object file` /
  `undefined symbol` / `GLIBCXX_x.y not found` 等日志直接失败；
- 不使用真实用户数据（曲库、凭据、偏好均指向临时目录）。

## 4. CI 接入

- `.github/actions/build-linux/action.yml`：`flutter build` + `bundle-linux-runtime.sh`
  之后依次执行依赖守卫与启动冒烟；任一失败则该发行版 job 失败。
- `packaging/linux/package.sh`：任何打包格式在开始处再跑一次依赖守卫（防止有人
  跳过 action 直接打包）。
- 各 Linux 发行版 job 安装 `xvfb` / X 认证 / 软件 GL / `dbus-run-session`。
- AppImage job 在产出后直接跑最终 `.AppImage`（`--appimage-extract-and-run`，无需
  FUSE），覆盖 linuxdeploy 收拢依赖 + AppRun 环境后的真实用户路径。

## 5. 新增依赖时怎么做

1. 先判断能否**内嵌**：能内嵌就加入 `bundle-linux-runtime.sh` 的收拢逻辑（不要改
   `DENY_RE` 放行），确认 `$ORIGIN` 生效。
2. 必须由系统提供时：
   - 在 `check_bundle_deps.sh` 的 `ALLOW_RE` 增加**精确 soname**；
   - 同步 `PKGBUILD` / `.spec` / deb `Depends` / `ebuild` / Nix / `vcpkg.json`
     的运行时依赖；
   - 在本文件第 2 节说明理由与 ABI 稳定性判断。
3. 跑：

```bash
# 本地：先按 CI 顺序构建并收拢运行库
cd app && flutter build linux --release
bash app/core/bundle-linux-runtime.sh app/build/linux/x64/release/bundle
bash app/tool/check_bundle_deps.sh   app/build/linux/x64/release/bundle
bash app/tool/smoke_start_linux.sh   app/build/linux/x64/release/bundle
```

## 6. 故障排查

| 报错 | 含义 / 处理 |
|---|---|
| `已内嵌 X，但运行时解析到 /usr/lib/...` | RUNPATH 丢失或被系统库顶替：确认跑了 `bundle-linux-runtime.sh`（需要 `patchelf`） |
| `RUNPATH 含非 $ORIGIN 路径` | 构建机绝对路径泄漏；同上，归一化 RUNPATH |
| `未登记的系统依赖 X` | 决策：内嵌，或把精确 soname 加入允许清单并补打包依赖 |
| `禁止直接依赖 libssl/libcrypto` | 回退到 Rust staticlib / 纯托管实现；不要把系统 OpenSSL 加回允许清单 |
| 启动冒烟 `进程提前退出` | 看日志尾部；常见为缺 GUI/GL/DBus 运行时、schema 或显示环境 |
| 启动冒烟 `依赖无法解析` | 与静态守卫同类问题；优先查 `$ORIGIN` 与内嵌完整性 |

## 7. 后续待办

- macOS：已有单架构 / Homebrew 绝对路径 / `dlopen` 全部 FFI 库检查与
  `archoerashell --version` 实跑；发行包为 DMG（打包脚本会挂载并校验 `.app` 主
  可执行文件）+ zip。待补带 GUI 的启动冒烟（CI 无 WindowServer 时需评估）；
- Windows：PE 导入表检查（`dumpbin /dependents`）+ `Start-Process` 存活冒烟；
- AppImage：已对最终 `.AppImage`（`--appimage-extract-and-run`）做启动冒烟。

已完成：scraper 的 HTTP 已从系统 `libcurl` 迁到内嵌 Rust `reqwest + rustls`
（`app/core/scraper-crypto/src/http.rs`，C ABI `era_http_*`），产物不再有
`libcurl` / OpenSSL 使用路径。
