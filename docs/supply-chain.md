# 发布供应链与 CI 加固

本文记录发布流水线（`.github/workflows/`）的供应链防护现状与**信任根取向**，
对应 [security-review-2026-10-11](security-review-2026-10-11.md) 第五批
（SEC-21 … SEC-27）与 SEC-08（原生完整性清单）。发布总流程见 [AGENTS.md §发布与签名](../AGENTS.md)。

## 1. 已落地

| 项 | 措施 | 位置 |
| --- | --- | --- |
| SEC-21 | 所有 GitHub Actions 依赖 **pin 到 40 位 commit SHA**（含签名作业），不再用可变主版本标签 | `build-all.yml`、`actions/build-linux/action.yml`、`security-audit.yml`、`codeql.yml` |
| SEC-22 | `protect-main` 开启 **Require review from Code Owners**：CI/签名/打包/水印等关键路径改动无法被非 owner 自合并（owner 为 bypass actor，可自建 PR 自合并） | GitHub ruleset + `.github/CODEOWNERS` |
| SEC-23 | `release` 作业在签名前**校验发版 tag 指向受保护长分支**（`main` 或 `ArchoeraOS`）的祖先提交，否则拒绝构建/签名 | `build-all.yml` release 作业 |
| SEC-24 | tag 名经 **`$GITHUB_REF_NAME` 环境变量**注入，`run:` 内不再内插 `${{ github.ref_name }}` | `build-all.yml` |
| SEC-25 | release 作业生成 **CycloneDX SBOM**：产物侧（FFmpeg / OpenSSL / opus / taglib 等原生库、自家二进制、Go 模块）+ 各生态锁文件（Rust 5× `Cargo.lock`、Dart `pubspec.lock`、Go `go.mod`+`go.sum`、.NET `packages.lock.json`）合并为一份；与**全部**资产一并签 `.sig1` 并列入 `SHA256SUMS`。另写入 **构建溯源 attestation**（`actions/attest-build-provenance`，Sigstore/OIDC） | `build-all.yml` release 作业、`app/tool/gen_sbom.sh` |
| SEC-26 | **各生态漏洞扫描**工作流（`cargo audit` / `govulncheck` / `dotnet list package --vulnerable`）；Dependabot 配置保留但**版本更新已停用**（依赖改为定期手动同步，见 §3） | `.github/dependabot.yml`、`security-audit.yml` |
| SEC-27 | CI 跑**完整 `flutter test`**（不再只跑 widget 冒烟）+ vault 用例（指向测试二进制）+ downloader/subsonic 的 `cargo test` / `go test` | `actions/build-linux/action.yml` |
| SEC-08 | release 作业对目录型产物的 `ARCHOERA-NATIVE-MANIFEST.txt` 做 **key1 ECDSA/SHA-256 分离签名**（`.sig1`），运行期内嵌公钥验签 + 摘要 | `build-all.yml` release 作业 + `app/tool/sign_native_manifest.sh` |

## 2. 信任根：应用层 key1 清单 + 分发渠道（2026-10 定稿）

**OS 代码签名不推进**：Windows **Authenticode**、macOS **公证（notarization）** 因成本与步骤不可得，
已**不再列为计划项**（不作为「待兑现承诺」）。当前的真实性机制如下：

### 2.1 应用层 key1 签名的原生完整性清单（F5）

- `native/` 全部文件（含 vault 二进制）在构建期生成 SHA-256 清单 `ARCHOERA-NATIVE-MANIFEST.txt`，
  由 **key1（ECDSA P-256 / SHA-256）** 签为 `ARCHOERA-NATIVE-MANIFEST.sig1`；
- 运行期 `NativeIntegrity` 用**二进制内嵌公钥**（`app/lib/app/watermark.dart`）**先验签、再逐文件比对摘要**，
  **fail-closed**；vault 二进制在 spawn 前亦经该校验（取代可伪造的 `PROD-*` marker 作主防线）；
- `release` 作业在**可被 release 控制的目录型产物**内注入签名清单——macOS / Windows tar、Linux 原始 bundle、
  Windows 便携 zip（`.github/workflows/build-all.yml` 的「签名原生完整性清单（SEC-08）」步骤）；
- **用户可离线核验**：用随发布分发的公钥（`ARCHOERA_PUBKEY.pem` / `watermark_pub.pem`）验 `.sig1` 与清单，
  无需信任任何服务器。

> 覆盖面边界：清单只覆盖 **release 作业能自行打包的产物**；`ARCHOERA_VAULT_BIN` 显式指定且 dev 无清单时跳过。

### 2.2 分发渠道信任

- **deb / rpm / AppImage / flatpak / pkg.tar.zst / nixos**：依赖**各发行版包管理器签名**，**不在 release 内重签**；
- **Windows Inno `.exe` 安装器**：依赖**外层 `.sig1`** 在安装前的核验，不对其内部清单重签；
- 官方产物仅以本仓库 GitHub Releases 为准；非官方渠道分发的产物官方不背书。

### 2.3 残余（如实声明，勿误判为已防护）

- **硬上限**：验证逻辑本身运行在**可被替换的进程**里——**替换主程序 / 同用户运行期注入主程序**无法用
  应用层清单防住；无 OS 代码签名、无硬件根（TPM / Secure Enclave）时无解。
- `.sig1` / 清单只证明「**key1 签了这份字节**」且「**这些文件与签名清单一致**」，**不证明构建来源可复现**。
- **每个构建作业自带溯源**：当前 provenance attestation 在 `release` 作业对**最终发布字节**生成；
  更严格的做法是在各构建矩阵作业内对各自产物即时 attest（需给每个作业
  `id-token: write` / `attestations: write`），属后续增强。
- **可复现构建**：未做 bit-for-bit 可复现验证。
- macOS 产物当前为 **ad-hoc 签名**（`CODE_SIGN_IDENTITY = "-"`），不再期待公证。

> 与 `vault-security-notes.md`「信任根边界」一致：上述残余为**已声明的威胁模型硬上限**，非「待兑现承诺」。

## 3. 维护要点

- 升级 Actions 时**保持 SHA pin**（pin 到目标版本 tag 对应的 40 位 commit SHA）。
- **依赖升级：定期手动同步**（2026-10-13 起）。Dependabot 的**版本更新已全量停用**
  （`.github/dependabot.yml` 各生态 `open-pull-requests-limit: 0`）：它会在缺少国内镜像的
  解析环境下重写 `app/pubspec.lock`（把 89 处 host 从 `pub.flutter-io.cn` 全量改回默认源）
  并批量开跨大版本 PR（含 release 关键路径）。改由维护者在本机（保留镜像）升级，
  跑通 `cargo test` / `go test` / `dart analyze lib` / `flutter test` 后再提交。
  需要恢复自动化时，把对应生态的 `open-pull-requests-limit` 改回正整数即可。
- `dtolnay/rust-toolchain` 因 pin 到 SHA，工具链经 `with: toolchain: stable` 指定（ref 不再是工具链名）。
- 新增任何 `uses:` 一律 pin SHA；`run:` 内**禁止**内插 `${{ github.* }}`（用环境变量）。
- **SBOM（SEC-25）**：`bash app/tool/gen_sbom.sh <artifacts_dir> <repo_root> <version> <out>`
  用 pin 版本的 syft（CI 内下载后按官方 `*_checksums.txt` 校验 sha256）扫「产物 + 锁文件」，
  再由 `app/tool/sbom_normalize.py` 归一化（主体标为 `ArchoeraMusic <版本>`、去掉
  `type: file` 条目与绝对路径、按 purl 去重、根节点展开全部组件）。
  **新增依赖生态时必须同步往脚本里加锁文件**，否则该生态会从 SBOM 里消失
  （脚本会打印「缺少依赖清单」提示）。已知边界：`licenses` 目前只有产物侧二进制
  自带的少量信息——锁文件不含许可字段，syft 的 `--enrich` 也只覆盖 Go/Java/JS/Python/vcpkg。
- **.NET 依赖清单**：`app/core/{scanner,indexer}/packages.lock.json`（`dotnet restore
  --use-lock-file` 生成，已入库）——SBOM 的 .NET 覆盖与 `dotnet list package --vulnerable`
  都以它为准；依赖变更后随 PR 一起更新。
- `release` 作业的 Environment 人工审批（`release`）是签名的最后一道人工门；SEC-23 的
  tag 祖先校验在其之前拦截「tag 指向未评审提交」。
- **漏洞处置**：`security-audit.yml` 首次运行即发现 downloader 的
  `rustls` RUSTSEC-2026-0285（已 `cargo update -p rustls --precise 0.23.45` 修复）。
  后续同类处置：downloader 的 `quinn-proto`（`reqwest` → `quinn`，仅存在于锁文件/
  特定 target，不在宿主构建图内）在 2026-10-12 公告库更新后命中
  RUSTSEC-2026-0338…0342（0.11.17 / 0.11.18 起修复），已
  `cargo update -p quinn-proto` 升至 0.11.19；同批把被 yank 的 `chacha20`
  （`rand 0.10` → `chacha20`）升至 0.10.2，消掉 audit 的 yanked 告警。
  两者都只动锁文件、不改 `Cargo.toml` 约束。
  确属**不适用**的公告才可经 `ignore` 放行，且须在 workflow 注释写明理由
  （如 RUSTSEC-2023-0071：`rsa` 仅用于公钥加密、不持私钥）。
- **2026-10-27 复扫（tokio）**：downloader 命中 RUSTSEC-2026-0386
  （tokio 1.53.2 的 `AsyncFd::new` / `try_new` / `with_interest` / `try_with_interest`
  违反 I/O safety；修复版 `>=1.51.6,<1.52.0` 或 `>=1.53.3`）。downloader **不调用
  `AsyncFd`**（只用到 tokio 的 fs/io-util/sync/time，其余经 reqwest 传递），无运行时
  暴露面；仍按「能升就升」执行 `cargo update -p tokio --precise 1.53.3`，只改
  `Cargo.lock`（tokio 的 `windows-sys` 解析随之回到 0.52，Windows 目标仍在依赖图内）。
  跟踪 issue #171 随本修复关闭。`paste`（RUSTSEC-2024-0436）维持 §4 的
  「不适用（编译期）」结论，issue #162 作为上游依赖跟踪项保留。
- **CodeQL 告警分级（2026-10-27）**：2026-10-22 启用 CodeQL 后首轮产生 44 条
  `cpp/*` 告警。其中 **36 条位于 vendored 第三方库**：`kernel/c/stb_vorbis.c` 的
  1 条指针溢出检查由 `.github/codeql/codeql-config.yml` 的 `paths-ignore` 排除并
  自动转为 fixed；`include/miniaudio.h` 的 35 条整数乘法提升**无法用路径过滤排除**
  （CodeQL 对 `#include` 进 `src/*.c` 的头文件不生效），已按 `won't fix` 逐条
  dismiss，升级 miniaudio 时复核是否出现新告警。**8 条位于自研代码**
  （`pipeline.c` 5 / `encoder.c` 1 / `main.c` 2），已按「乘法先提升 `size_t` +
  溢出检查」「JSON 追加统一校验剩余空间」加固，合并后新一轮 main 扫描已全部转为
  fixed。自研目录（`src/`、`kernel/*.zig`、`app/native/**`）**不得**加入
  `paths-ignore`。

## 4. 已知风险与例外

以下条目是**已评估并接受**的已知风险（或纯属误报/不适用），在此集中登记，避免被
误判为「尚未发现」或「已修复」。新增例外须同样写明理由、影响面与复核条件。

- **RUSTSEC-2023-0071（`rsa` Marvin 计时侧信道）——不适用**：
  该公告只影响**持有私钥**、执行解密/签名的一方。downloader 仅用
  `RsaPublicKey::encrypt`（酷狗登录公钥加密，见 `app/core/downloader/src/crypto.rs`），
  **不持私钥、不做解密**，故攻击面不存在。已在 `security-audit.yml` 的 `ignore`
  中登记（附同样理由的注释），待上游 `rsa` 出补丁后复核是否可以去掉该 ignore。
- **RUSTSEC-2024-0436（`paste` crate 停止维护）——不适用（编译期）**：
  该 crate 经 `lofty`（downloader 的标签/元数据处理依赖，`Cargo.toml` 中 `lofty = "0.25"`）
  传递引入，是 **proc-macro**，只在编译期展开宏，**无运行时暴露面**，也不进入发布产物。
  `cargo audit` 将其归为 **warning**（unmaintained）而**不拦截**构建；等 `lofty`
  换用其它实现（或版本升级去掉该依赖）后该项自然消失。
- **第三方音源明文 HTTP 端点——上游既定行为，MITM 可篡改内容**：
  `http://login.user.kugou.com`（短信验证码发送，见 `app/lib/services/kugou/kugou_request.dart`）、
  `http://lyrics.kugou.com`（歌词搜索/下载，见 `app/core/downloader/src/metadata.rs`）、
  `http://mobilecdn.kugou.com`（歌曲搜索，同上）、`http://aqqmusic.tc.qq.com`（QQ 音乐媒体直链；
  downloader 的重定向白名单允许公网明文 http，示例见 `app/core/downloader/src/lib.rs`）
  均走**明文 HTTP**：这是**上游服务的既定行为**，客户端无法单方面改成 TLS。
  影响面：同网络路径上的 MITM 可**篡改歌词/媒体内容**（返回错误歌词、替换音频流），
  也可能观察到查询参数（关键词、手机号在查询串中）。
  **不触及本地凭据保险库**：vault 全本地、文件权限 `0600`、敏感缓冲释放前 `zeroize`，
  且上述明文请求不携带 vault 内的令牌/密码。若上游提供 https 端点，应**优先替换**。
- **`os/vm/mkosi.key` 从未入库（提醒）**：本地镜像构建密钥被 `.gitignore` 的 `*.key`
  规则覆盖，`git ls-files` 中不存在该文件。维护者**不要**用 `git add -f` 强加——一旦
  入库即使后续删除也会留在历史里，需整条历史重写才能清除。
