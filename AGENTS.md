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

## 发布与双签名（双控）

发布产物采用**两把独立密钥各签一次**的双控方案（单把私钥泄露不足以伪造）：

| 签名 | 私钥 | 执行者 | 产物 | 是否进 CI |
|---|---|---|---|---|
| key1 | `watermark_ec_priv.pem` | CI（`release` Environment，人工审批） | `<asset>.sig1` | 是（受保护 Environment secret） |
| key2 | `watermark2_ec_priv.pem` | **维护者本地** | `<asset>.sig2` | **否** |

公钥：`app/tool/watermark_pub.pem`（key1）、`app/tool/watermark_pub2.pem`（key2），
随 Release 分发（`ARCHOERA_PUBKEY.pem` / `ARCHOERA_PUBKEY2.pem`）。私钥**绝不入库/入包**。

### 发布流程
1. 打 tag（`v*`）→ CI 构建三端产物。
2. `release` 作业进入 **Environment 审批**：人工批准后，CI 用 key1 对全部资产签 `.sig1`，
   复制两把公钥，创建/更新 GitHub Release。
3. **维护者本地**用 key2 签 `.sig2` 并上传到该 Release（见下）。
4. 两把签名齐全且验签通过，才算「官方发布」。

### 维护者本地补签 key2（每次 Release 必做）
```bash
TAG=v0.9.15
mkdir -p /tmp/rel && gh release download "$TAG" -D /tmp/rel --clobber
# 仅用 key2 签（ARCHOERA_WM_KEYS=2；默认文件 ~/.config/archoera/watermark2_ec_priv.pem）
ARCHOERA_WM_KEYS=2 bash app/tool/sign_release.sh /tmp/rel
gh release upload "$TAG" /tmp/rel/*.sig2 --clobber
```
Windows/无 shell 环境可用跨平台 Dart 版：
```powershell
$env:ARCHOERA_WM_KEYS="2"; $env:ARCHOERA_WM_PRIVKEY2_D="<key2标量hex>"
dart run tool/sign_release.dart sign C:\path\to\rel
```

### 验签（任何人）
```bash
bash app/tool/verify_release.sh /tmp/rel
# 或逐文件：
openssl dgst -sha256 -verify app/tool/watermark_pub.pem  -signature x.sig1 x
openssl dgst -sha256 -verify app/tool/watermark_pub2.pem -signature x.sig2 x
```
`verify_release.sh` 为**双控**：`x.sig1` 与 `x.sig2` **都**必须存在且有效。

### 密钥生成 / 轮换
```bash
# key1（同时用于二进制内水印，常量写入 app/lib/app/watermark.dart）
bash app/tool/sign_watermark.sh          # 本地运行；CI 环境会拒绝执行
# key2（仅发布签名）
openssl ecparam -name prime256v1 -genkey -noout -out ~/.config/archoera/watermark2_ec_priv.pem
chmod 600 ~/.config/archoera/watermark2_ec_priv.pem
openssl ec -in ~/.config/archoera/watermark2_ec_priv.pem -pubout -out app/tool/watermark_pub2.pem
```
轮换后需同步更新：`watermark.dart` 常量、`sign_release.dart` 内公钥 hex、
`watermark_pub*.pem`、以及 CI 的 Environment secret。旧发布保留旧公钥以便历史验签。

### 私钥材料（切勿提交/打印）
- key1：`~/.config/archoera/watermark_ec_priv.pem`
- key2：`~/.config/archoera/watermark2_ec_priv.pem`
- CI secret（**Environment `release`**，非仓库级）：`ARCHOERA_WM_KEY1_PEM`（key1 PEM）。
- key2 **不进 CI**；其 PEM/标量仅本地持有。

## 仓库保护（已在 GitHub 配置）
- **Environment `release`**：Required reviewers = 维护者；部署仅允许 tag `v*`；
  含 Environment secret `ARCHOERA_WM_KEY1_PEM`（key1 PEM）。
- **Ruleset `protect-main`**（branch）：要求 PR、禁止强推（non_fast_forward）、禁止删除；
  Required approvals = 0（单人可自建 PR 自合并）。**禁止直接 push `main`**。
- **Ruleset `protect-release-tags`**（tag `v*`）：禁止**更新/删除**已发布 tag（不可移动）。
  故打 tag 前务必确认版本号。
- **CODEOWNERS**：`.github/CODEOWNERS` 把 CI/工具/打包/水印等关键路径指向维护者。

## 触发一次 Release（端到端）
1. **升版本**：改 `app/pubspec.yaml` 的 `version:`（如 `0.9.15+5`）。
2. **提交**：因 `protect-main` 禁直推，走 PR：`git switch -c chore/release-x` →
   commit → push → `gh pr create` → 自合并（0 approvals 即可）。
3. **打 tag 并推**：`git tag v<version> && git push origin v<version>`
   （`v*` 匹配部署策略；**tag 一旦推送不可删改**）。
4. **审批**：Actions → 该 run 的 release 作业停在 **Waiting for review** → Approve。
   CI 用 key1 签 `<asset>.sig1`、复制两把公钥、创建 Release。
5. **本地补签 key2**：见上「维护者本地补签 key2」→ 上传 `.sig2`。
6. 双签齐全 → 官方发布完成。

## 红线
- 禁止提交任何私钥/凭据（`.gitignore` 已忽略 `*.key`、`*_priv.pem`；公钥 `watermark_pub*.pem` 需跟踪）。
- 禁止在 CI 运行 `sign_watermark.sh`（会打印私钥材料；脚本已加 `CI` 环境拒绝）。
- 签名步骤不要开 `set -x`；`ARCHOERA_WM_KEYS` 控制本次签哪把（`1` / `2` / `1,2`）。

