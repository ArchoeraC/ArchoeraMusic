# 发布供应链与 CI 加固

本文记录发布流水线（`.github/workflows/`）的供应链防护现状与**信任根取向**，
对应 [security-review-2026-10-11](security-review-2026-10-11.md) 第五批
（SEC-21 … SEC-27）与 SEC-08（原生完整性清单）。发布总流程见 [AGENTS.md §发布与签名](../AGENTS.md)。

## 1. 已落地

| 项 | 措施 | 位置 |
| --- | --- | --- |
| SEC-21 | 所有 GitHub Actions 依赖 **pin 到 40 位 commit SHA**（含签名作业），不再用可变主版本标签 | `build-all.yml`、`actions/build-linux/action.yml`、`security-audit.yml` |
| SEC-22 | `protect-main` 开启 **Require review from Code Owners**：CI/签名/打包/水印等关键路径改动无法被非 owner 自合并（owner 为 bypass actor，可自建 PR 自合并） | GitHub ruleset + `.github/CODEOWNERS` |
| SEC-23 | `release` 作业在签名前**校验发版 tag 指向受保护长分支**（`main` 或 `ArchoeraOS`）的祖先提交，否则拒绝构建/签名 | `build-all.yml` release 作业 |
| SEC-24 | tag 名经 **`$GITHUB_REF_NAME` 环境变量**注入，`run:` 内不再内插 `${{ github.ref_name }}` | `build-all.yml` |
| SEC-25 | release 作业生成 **CycloneDX SBOM** 并写入 **构建溯源 attestation**（`actions/attest-build-provenance`，Sigstore/OIDC） | `build-all.yml` release 作业 |
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
