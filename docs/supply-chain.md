# 发布供应链与 CI 加固

本文记录发布流水线（`.github/workflows/`）的供应链防护现状与**未完成项**，
对应 [security-review-2026-10-11](security-review-2026-10-11.md) 第五批
（SEC-21 … SEC-27）。发布总流程见 [AGENTS.md §发布与签名](../AGENTS.md)。

## 1. 已落地

| 项 | 措施 | 位置 |
| --- | --- | --- |
| SEC-21 | 所有 GitHub Actions 依赖 **pin 到 40 位 commit SHA**（含签名作业），不再用可变主版本标签 | `build-all.yml`、`actions/build-linux/action.yml`、`security-audit.yml` |
| SEC-22 | `protect-main` 开启 **Require review from Code Owners**：CI/签名/打包/水印等关键路径改动无法被非 owner 自合并（owner 为 bypass actor，可自建 PR 自合并） | GitHub ruleset + `.github/CODEOWNERS` |
| SEC-23 | `release` 作业在签名前**校验发版 tag 指向受保护长分支**（`main` 或 `ArchoeraOS`）的祖先提交，否则拒绝构建/签名 | `build-all.yml` release 作业 |
| SEC-24 | tag 名经 **`$GITHUB_REF_NAME` 环境变量**注入，`run:` 内不再内插 `${{ github.ref_name }}` | `build-all.yml` |
| SEC-25 | release 作业生成 **CycloneDX SBOM** 并写入 **构建溯源 attestation**（`actions/attest-build-provenance`，Sigstore/OIDC） | `build-all.yml` release 作业 |
| SEC-26 | 新增 **Dependabot**（github-actions / cargo / gomod / nuget / pub）与**各生态漏洞扫描**工作流（`cargo audit` / `govulncheck` / `dotnet list package --vulnerable`） | `.github/dependabot.yml`、`security-audit.yml` |
| SEC-27 | CI 跑**完整 `flutter test`**（不再只跑 widget 冒烟）+ vault 用例（指向测试二进制）+ downloader/subsonic 的 `cargo test` / `go test` | `actions/build-linux/action.yml` |

## 2. 未完成（信任根缺口，需后续闭环）

以下为 SEC-25 的**信任根承诺尚未兑现**部分，读者/下游不得据 §1 误判为「产物已具备 OS 信任链」：

- **Windows**：未做 **Authenticode** 代码签名（安装包 / 可执行）。
- **macOS**：仅 **ad-hoc 签名**（`CODE_SIGN_IDENTITY = "-"`），未做 **Apple 公证（notarization）**。
  这需要 Apple Developer ID 证书与 `notarytool` 凭据（CI secret），当前未配置。
- **每个构建作业自带溯源**：当前 provenance attestation 在 `release` 作业对**最终发布字节**
  生成；更严格的做法是在**各构建矩阵作业**内对各自产物即时 attest（需给每个作业
  `id-token: write` / `attestations: write`），属后续增强。
- **可复现构建**：未做 bit-for-bit 可复现验证。

> 上述缺口与 `vault-security-notes.md`「信任根边界」一致：应用层 `.sig1`（key1）只证明
> 「该密钥签了这份字节」，**不**证明构建来源；二进制层面的「未被替换」依赖上表 OS 信任链，
> 目前**未兑现**。

## 3. 维护要点

- 升级 Actions 时**保持 SHA pin**（Dependabot 的 `github-actions` 会自动发 PR，合并后仍为 SHA）。
- `dtolnay/rust-toolchain` 因 pin 到 SHA，工具链经 `with: toolchain: stable` 指定（ref 不再是工具链名）。
- 新增任何 `uses:` 一律 pin SHA；`run:` 内**禁止**内插 `${{ github.* }}`（用环境变量）。
- `release` 作业的 Environment 人工审批（`release`）是签名的最后一道人工门；SEC-23 的
  tag 祖先校验在其之前拦截「tag 指向未评审提交」。
- **漏洞处置**：`security-audit.yml` 首次运行即发现 downloader 的
  `rustls` RUSTSEC-2026-0285（已 `cargo update -p rustls --precise 0.23.45` 修复）。
  确属**不适用**的公告才可经 `ignore` 放行，且须在 workflow 注释写明理由
  （如 RUSTSEC-2023-0071：`rsa` 仅用于公钥加密、不持私钥）。
