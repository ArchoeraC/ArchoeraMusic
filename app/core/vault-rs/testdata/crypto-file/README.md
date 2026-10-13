# 黄金夹具：crypto（'C'，file 后端）

> **公开测试凭据**（口令/密钥均为测试值，非真实凭据）。

- 解锁材料：`secret.key` 固定主密钥 `00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff`

- 条目：`kugou:session` = `golden-kugou-session-token`；`netease:cookie` = `golden-netease-cookie-value`
- KDF：默认档
- 生成：`app/core/vault-rs/gen_testdata.sh`（生成后**入库冻结**；仅当确认格式未变才重新生成）

**用途**：容器格式与 KDF/HKDF/AEAD 语义的字节兼容锚点。读取用例见
`app/core/vault-rs/test.sh` §14 与 `test-windows.sh`（Windows 读同一份夹具）。
