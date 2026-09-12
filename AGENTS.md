# AGENTS.md — ArchoeraMusic 维护与发布指引

本文件面向在本仓库工作的 AI 助手与维护者，记录**发布/签名**等关键流程。
通用贡献规范见 `CONTRIBUTING.md`。

## 构建与测试（提交前必跑）
```bash
cd app
flutter pub get
dart analyze lib            # 0 issue
flutter test                # 全绿
```
改动原生模块（`app/core/audio-engine`）时另跑：
```bash
cd app/core/audio-engine
zig build -Doptimize=ReleaseFast
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
cd build && ctest
```

## 发布与签名

发布产物用**一把密钥（key1）**做 ECDSA P-256 / SHA-256 分离签名（`<asset>.sig1`），
由 CI 在受保护 `release` Environment（人工审批）执行；公钥随发布分发
（`ARCHOERA_PUBKEY.pem`）。私钥**绝不入库/入包**。

### 发布流程
1. 升版本 + **更新 `CHANGELOG.md`**（见下节）。
2. 打 tag（`v*`）→ CI 构建三端产物。
3. `release` 作业进入 **Environment 审批**：人工批准后，CI 用 key1 对全部资产签 `.sig1`，
   复制公钥，按 tag 从 `CHANGELOG.md` 抽取说明创建/更新 GitHub Release。

### 更新日志（CHANGELOG.md）
- 根目录 `CHANGELOG.md` 是各版本 **GitHub Release 说明的唯一来源**：release 作业按 tag
  抽取对应 `## [<version>]` 段落作为 Release 正文（见 `.github/workflows/build-all.yml`）。
- **文风**：新增条目须**沿用当前作者的风格**（口语化、「喵」、编号列表等），
  不要改成正式 Keep-a-Changelog 腔调。
- **每次发版必须更新**：在 `CHANGELOG.md` 顶部加一段
  `## [<version>] - <YYYY-MM-DD>`（与 `pubspec.yaml` 的 `version:`、git tag 一致）。
  缺段落时 Release 回退到通用文案。

### 验签（任何人）
```bash
bash app/tool/verify_release.sh /tmp/rel
# 或逐文件：
openssl dgst -sha256 -verify app/tool/watermark_pub.pem -signature x.sig1 x
```

### 密钥生成 / 轮换
```bash
# key1（同时用于二进制内水印，常量写入 app/lib/app/watermark.dart）
bash app/tool/sign_watermark.sh          # 本地运行；CI 环境会拒绝执行
```
轮换后需同步更新：`watermark.dart` 常量、`watermark_pub.pem`、CI 的 Environment secret。
旧发布保留旧公钥以便历史验签。

### 私钥材料（切勿提交/打印）
- key1：`~/.config/archoera/watermark_ec_priv.pem`
- CI secret（**Environment `release`**，非仓库级）：`ARCHOERA_WM_KEY1_PEM`（key1 PEM）。

## 仓库保护（已在 GitHub 配置）
- **Environment `release`**：Required reviewers = 维护者；部署仅允许 tag `v*`；
  含 Environment secret `ARCHOERA_WM_KEY1_PEM`（key1 PEM）。
- **Ruleset `protect-main`**（branch）：要求 PR、禁止强推（non_fast_forward）、禁止删除；
  Required approvals = 0（单人可自建 PR 自合并）。**禁止直接 push `main`**。
- **Ruleset `protect-release-tags`**（tag `v*`）：禁止**更新/删除**已发布 tag（不可移动）。
  故打 tag 前务必确认版本号。
- **CODEOWNERS**：`.github/CODEOWNERS` 把 CI/工具/打包/水印等关键路径指向维护者。

## 触发一次 Release（端到端）
1. **升版本**：改 `app/pubspec.yaml` 的 `version:`（如 `0.9.15+8`）。
2. **更新 `CHANGELOG.md`**：顶部加 `## [<version>] - <YYYY-MM-DD>` 段，沿用作者文风。
3. **提交**：因 `protect-main` 禁直推，走 PR：`git switch -c chore/release-x` →
   commit → push → `gh pr create` → 自合并（0 approvals 即可）。
4. **打 tag 并推**：`git tag v<version> && git push origin v<version>`
   （`v*` 匹配部署策略；**tag 一旦推送不可删改**）。
5. **审批**：Actions → 该 run 的 release 作业停在 **Waiting for review** → Approve。
   CI 用 key1 签 `<asset>.sig1`、复制公钥、按 tag 抽取 `CHANGELOG.md` 段落作为
   Release 正文 → 官方发布完成。

## 红线
- 禁止提交任何私钥/凭据（`.gitignore` 已忽略 `*.key`、`*_priv.pem`；公钥 `watermark_pub*.pem` 需跟踪）。
- 禁止在 CI 运行 `sign_watermark.sh`（会打印私钥材料；脚本已加 `CI` 环境拒绝）。
- 签名步骤不要开 `set -x`。

