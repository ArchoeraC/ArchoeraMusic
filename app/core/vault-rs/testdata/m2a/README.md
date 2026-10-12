# 黄金夹具：slots m2a（'S'，口令+设备槽 + 恢复槽）

> **公开测试凭据**（口令/密钥均为测试值，非真实凭据）。

- 解锁材料：口令 `golden-m2a-pw`（或恢复码）
- 恢复码（m2a 备用解锁）：`H1WA-06E1-DVEA-EJFG-S66Y-64ZP-BCG3-N08J-VZPQ-0F6Y-77DN-CG24-9R40`
- 条目：`kugou:session` = `golden-kugou-session-token`；`netease:cookie` = `golden-netease-cookie-value`
- KDF：最小档 m=8192 / t=1 / p=1（仅口令+设备槽）
- 生成：`app/core/vault-rs/gen_testdata.sh`（生成后**入库冻结**；仅当确认格式未变才重新生成）

**用途**：容器格式与 KDF/HKDF/AEAD 语义的字节兼容锚点。读取用例见
`app/core/vault-rs/test.sh` §14 与 `test-windows.sh`（Windows 读同一份夹具）。
