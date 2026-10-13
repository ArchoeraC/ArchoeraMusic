# vault 格式黄金夹具（golden fixtures）

> 全部为**公开测试凭据**（口令/密钥/恢复码都是测试值），不是真实凭据。

`app/core/vault/`（C# 版）已删除，故用**冻结夹具**承担容器格式（crypto `'C'` / slots `'S'`）
与 KDF/HKDF/AEAD 语义的字节兼容锚点：夹具由当时的实现一次性生成并入库，读取用例
（`test.sh` §14 / `test-windows.sh`）必须永远能解开并读回固定值——任何破坏读取兼容性的
改动都会立刻失败。重新生成只在**确认格式未变**时进行（`./gen_testdata.sh`）。

| 夹具 | 模式 | 解锁材料 | 备注 |
|---|---|---|---|
| `crypto-file/` | crypto `'C'` + file 后端 | 固定主密钥（见目录 README） | 亦覆盖 `backend` 指纹 = `file` |
| `m1/` | slots `'S'` m1 | 口令 | KDF 最小档（快速） |
| `m2a/` | slots `'S'` m2a | 口令 或 恢复码 | 覆盖 pwdev / recovery 两条 HKDF 路径 |
| `m2b/` | slots `'S'` m2b | `device.key` | 覆盖 device 路径 |

条目固定为：`kugou:session` = `golden-kugou-session-token`、
`netease:cookie` = `golden-netease-cookie-value`。
