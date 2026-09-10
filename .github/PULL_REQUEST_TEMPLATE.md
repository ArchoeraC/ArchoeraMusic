<!-- 提交规范见 CONTRIBUTING §7：Commit 遵循 type(scope): 中文描述 -->

## 动机与方案

<!-- 关联 Issue：# 编号；解决了什么问题、方案要点 -->

## 改动范围

<!-- 勾选触及的模块 -->
- [ ] Dart（`app/lib` / `app/test`）
- [ ] C / Zig（audio-engine）
- [ ] C#（scanner / vault）
- [ ] C++（scraper）
- [ ] Rust（downloader / tempo-rs / transcoder）
- [ ] Go（subsonic）
- [ ] 文档（docs / README / 模块 README）
- [ ] CI / 构建（workflows / 脚本 / 打包）

## 验收证据

- [ ] `flutter analyze` 0 issue
- [ ] `flutter test` 全绿
- [ ] 原生模块构建 / 测试（如适用，注明模块与命令）：
- [ ] 已验证平台：Linux / Windows / macOS（未覆盖的端说明原因与风险，红线 §2.2）

## AI 参与声明（红线 §2.3，必填）

- 参与程度：无 / 轻度补全 / 大段生成（选一）
- [ ] 已完成人工逐行审核，理解全部改动
- [ ] 已附本地测试证据

## 检查清单

- [ ] 接受贡献者授权（README §2.2，AGPL-3.0-or-later 不可撤销再许可）
- [ ] 未触碰红线（CONTRIBUTING §2.1–2.6：广告 / 付费墙 / frp / 遥测 / 非 FFI 运行时 / 平台歧视 / 舞弊 / 注入 / 供应链投毒 / 非公开依赖 / 个人数据）
- [ ] 新增依赖已登记 `THIRD-PARTY-LICENSES.md` 且许可合规（§9）；锁定文件已更新
- [ ] 新增数据存储已在描述中注明存储位置与访问方（§2.5）
- [ ] 主张「平台硬性限制」的已附依据（§2.2）
- [ ] 文档已同步（§8：architecture / README / 模块文档）
- [ ] 无调试残留、死代码、无关格式化噪音（代码纯净，§2.3）
