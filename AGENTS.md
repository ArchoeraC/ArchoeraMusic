# AGENTS.md — ArchoeraMusic 维护与发布指引

面向在本仓库工作的 AI 助手与维护者，只保留**构建门禁、发布/签名**等实操要点。
通用贡献规范见 `CONTRIBUTING.md`，架构决策见 `docs/architecture.md`。

## 工作范围
- **除非特别说明，不要自行管理其它项目**：只处理本项目的修改，不改动、清理或操作仓库之外的其它项目与目录。

## 提交前必跑
```bash
cd app && flutter pub get
dart analyze lib      # 0 issue
flutter test          # 全绿
```

> CI（`.github/workflows/build-all.yml`）**只做编译与打包、不跑测试**：单测/回归
> 的门禁完全依赖上面的本地步骤，别指望 Actions 帮你兜底。
> 真实网络用例默认跳过，需要时 `ARCHOERA_ONLINE_TEST=1 flutter test` 显式启用。

改动以下模块时另跑：

```bash
# 音频引擎
cd app/core/audio-engine
zig build -Doptimize=ReleaseFast
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
(cd build && ctest)

# 平台桥接（末条为 ABI 契约符号守卫）
cmake -S app/native/platform -B app/native/platform/build -DCMAKE_BUILD_TYPE=Release
cmake --build app/native/platform/build -j
cd app && flutter test test/native_platform_abi_test.dart

# 内嵌 CLI（Rust staticlib，三端 archoerashell）
cargo test --release --manifest-path app/core/shell/Cargo.toml
for t in x86_64-pc-windows-msvc aarch64-apple-darwin x86_64-apple-darwin; do
  cargo build --release --target "$t" --manifest-path app/core/shell/Cargo.toml   # 交叉静态检查
done

# 凭据保险库
cd app/core/vault-rs && ./build-test.sh && ./test.sh
./test-windows.sh     # Wine 上跑真实产物，缺依赖则跳过
./cross-macos.sh      # 仅编译期检查，运行期待真机
```

- 改 `app/lib/l10n/*.arb` 后跑 `flutter gen-l10n`，并先跑一次 shell 的 `cargo test`（`build.rs` 从 ARB 生成帮助文案）。
- 改了 Zig 内核，构建前先 `rm -f app/core/audio-engine/build/libarchoera_kernel.a`，否则 CMake 会复用旧库。
- `gen_testdata.sh` 仅在确认容器格式未变时执行（黄金夹具是字节兼容锚点）。
- 命令行实现只有 Rust 一份；`flutter build` 会自动编译该 staticlib。Windows REPL/脚本用 `archoerashell.exe`；细节见 `docs/mcp.md` §6。
- Windows 自检：`zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast`；严格 MSVC 以 Windows CI 为准。新增 C/ABI 代码不得引入 `unistd.h`/POSIX-only API，线程原语走 `include/compat/pthread.h`。

## 架构约定（摘要，完整规则见 `CONTRIBUTING.md` §4）
- **系统能力只走 C++ 桥接器**：一律在 `app/native/platform` 实现，Dart 仅经 `apl_*` C ABI 调用；禁止 MethodChannel/插件、`Process.run`、Dart 侧解析平台数据。新增能力流程见 `docs/platform-native-bridge.md`。
- **最小权限**：运行时不得请求管理员/root，不写 `HKLM`/系统目录，不装服务或驱动；需要提权的能力放弃或降级。唯一例外是 Windows 安装向导的可选 per-machine 模式（默认必须 per-user 免提权）。
- **模块化**：按职责拆文件、单一职责；共享逻辑放 `core.*` / `backend.h`，平台特有逻辑放各平台后端文件。
- **命名原创**：自有符号不得照搬 FFmpeg/libopus 等上游标识符；内核表与内部常量统一 `era_` 前缀。注释可引用上游作为溯源。
- **渲染性能**：高渲染压力优先 GPU（shader / `FragmentProgram`），重计算下沉后台 isolate 或原生层，UI 线程只做调度；范例见 `docs/player-render-optimization.md`。
- **内核并发**：Zig 内核为同步 run-to-completion，禁止 `await`；禁止用 `sleep`/轮询"凑"竞态断言，只断言完成后稳定的值或任意时刻成立的不变量；偶发失败要确定性化，不得靠重试掩盖。

## 发布与签名
发布产物用 **key1** 做 ECDSA P-256 / SHA-256 分离签名（`<asset>.sig1`），由 CI 在受保护的 `release` Environment（人工审批）执行；公钥随发布分发。私钥**绝不入库/入包**。

一次发布：
1. 改 `app/pubspec.yaml` 的 `version:`，并在 `CHANGELOG.md` 顶部加 `## [<version>] - <YYYY-MM-DD>`（与 tag 一致）。CHANGELOG 是 Release 说明的唯一来源，文风沿用现有条目（口语化、「喵」、编号列表）。
2. 走 PR 合并（`main` 禁直推）：`git switch -c chore/release-x` → commit → push → `gh pr create` → 自合并。
3. `git tag v<version> && git push origin v<version>`（tag 推送后不可删改）。
4. Actions 中 release 作业停在 **Waiting for review** → Approve：CI 签 `.sig1`、附公钥、按 tag 抽取 CHANGELOG 段落创建 Release。

验签：
```bash
bash app/tool/verify_release.sh /tmp/rel
```
轮换密钥：本地跑 `bash app/tool/sign_watermark.sh`（CI 会拒绝），随后同步 `app/lib/app/watermark.dart`、`app/tool/watermark_pub.pem` 与 Environment secret。

私钥材料（切勿提交/打印）：本地 `~/.config/archoera/watermark_ec_priv.pem`；CI 用 Environment `release` 的 `ARCHOERA_WM_KEY1_PEM`。

## Git 与仓库保护
- `origin` 用 SSH，提交/标签用 GPG 签名（`user.signingkey`、`commit.gpgsign true`、`tag.gpgsign true`）。发现仍在用 PAT 时，主动建议换成密钥方案。
- `main`：必须 PR，禁止强推/删除；Code Owners 覆盖 CI/签名/打包/水印。维护者是 bypass actor，可自建 PR 自合并。
- `ArchoeraOS`：长期发行版分支，禁止删除/强推，不要求 PR，也不得并入 `main` 后删除。
- `v*` tag：禁止更新/删除。

## 红线
- 禁止提交私钥/凭据/token；凭据只留在本地密钥环。
- 禁止在 CI 跑 `sign_watermark.sh`；签名步骤不要开 `set -x`。
- 禁止 `pkill -x` 自杀式结束进程。
- "Hmm" 等可能导致死循环的内容，尽量不要触及。
- 更新提交后，首次 CI 验证必须跑全平台。
