#!/usr/bin/env bash
# 生成 vault 格式「黄金夹具」（golden fixtures）——替代已废弃的 C# 活体 oracle。
#
# 为什么需要：`app/core/vault/`（C# 版）删除后，容器格式（crypto 'C' / slots 'S'）与
# KDF/HKDF/AEAD 语义的**字节兼容性**需要有独立锚点，否则一次无意的格式改动不会被任何
# 测试发现。夹具用当前实现一次性生成、**入库冻结**：任何改动只要破坏读取兼容性，
# 「读夹具」用例就会失败（比活体 oracle 更稳、更省、不需要 .NET）。
#
# 夹具内容（`app/core/vault-rs/testdata/`，均为**公开测试凭据**，非真实密钥）：
#   crypto-file/  init-file（固定 hex 主密钥）→ 2 条目
#   m1/           init-m1（口令，KDF 取最小值 8192/1/1 以便快速验证）
#   m2a/          init-m2a（口令 + device.key + 恢复码）
#   m2b/          init-m2b（仅 device.key）
# 每个目录附 README.md 记录解锁材料与条目明文；条目明文见下（uid=value）。
#
# 用法：./gen_testdata.sh          # 重新生成（会覆盖）——仅在**确认格式未变**时使用
set -euo pipefail
cd "$(dirname "$0")"

VAULT="build/archoera-vault-test"
[ -x "$VAULT" ] || { echo "缺少测试产物，先运行 ./build-test.sh" >&2; exit 1; }
export ARCHOERA_VAULT_BACKEND=file

ROOT="testdata"
FIXED_KEY="00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
PW_M1="golden-m1-pw"
PW_M2A="golden-m2a-pw"
ENTRIES=$'kugou:session=golden-kugou-session-token\nnetease:cookie=golden-netease-cookie-value'

# 机器可读的夹具元数据（测试的唯一事实源；README 供人阅读，测试不解析 README）。
write_unlock() { # <dir> <json> —— 经 python 校验，杜绝非法 JSON 入库
  printf '%s\n' "$2" | python3 -c 'import json,sys; d=json.load(sys.stdin); json.dump(d, open(sys.argv[1],"w"), ensure_ascii=False, indent=1)' "$1/unlock.json"
}
write_readme() { # <dir> <mode 说明> <解锁材料> [恢复码]
  local dir="$1" mode="$2" unlock="$3" code="${4:-}"
  cat > "$dir/README.md" <<EOF
# 黄金夹具：$mode

> **公开测试凭据**（口令/密钥均为测试值，非真实凭据）。

- 解锁材料：$unlock
${code:+- 恢复码（m2a 备用解锁）：\`$code\`}
- 条目：\`kugou:session\` = \`golden-kugou-session-token\`；\`netease:cookie\` = \`golden-netease-cookie-value\`
- KDF：${KDF_NOTE:-默认档}
- 生成：\`app/core/vault-rs/gen_testdata.sh\`（生成后**入库冻结**；仅当确认格式未变才重新生成）

**用途**：容器格式与 KDF/HKDF/AEAD 语义的字节兼容锚点。读取用例见
\`app/core/vault-rs/test.sh\` §14 与 \`test-windows.sh\`（Windows 读同一份夹具）。
EOF
}

rm -rf "$ROOT"
mkdir -p "$ROOT"

echo "== crypto-file（file 后端，固定主密钥）=="
D="$ROOT/crypto-file"; mkdir -p "$D"
printf '%s\n' "$FIXED_KEY" | "$VAULT" init-file "$D" --key-stdin >/dev/null
python3 - "$VAULT" "$D" <<'PY'
import base64, os, subprocess, sys
vault, d = sys.argv[1:3]
p = subprocess.Popen([vault, "serve", d], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     env=dict(os.environ, ARCHOERA_VAULT_BACKEND="file"))
def cmd(l, pl=None):
    p.stdin.write((l + "\n" + (pl + "\n" if pl else "")).encode()); p.stdin.flush()
    return p.stdout.readline().decode().strip()
b32 = base64.b64encode(bytes(range(32))).decode()
b16 = base64.b64encode(bytes(range(16))).decode()
assert cmd("handshake %s %s" % (b32, b16)).startswith("ok handshake")
for uid, val in (("kugou:session", "golden-kugou-session-token"),
                 ("netease:cookie", "golden-netease-cookie-value")):
    assert cmd("set " + uid, base64.b64encode(val.encode()).decode()) == "ok"
cmd("quit"); p.wait(timeout=30)
rm -f "$D/vault.lock"
PY
write_readme "$D" "crypto（'C'，file 后端）" "\`secret.key\` 固定主密钥 \`$FIXED_KEY\`"
write_unlock "$D" '{"mode":"crypto","backend":"file","kdf":null,
  "entries":{"kugou:session":"golden-kugou-session-token","netease:cookie":"golden-netease-cookie-value"}}' 

echo "== m1（口令，最小 KDF）=="
D="$ROOT/m1"; mkdir -p "$D"
KDF_NOTE="最小档 m=8192 / t=1 / p=1" printf '%s\n' "$PW_M1" | \
  "$VAULT" init-m1 "$D" --kdf-m 8192 --kdf-t 1 --kdf-p 1 >/dev/null
python3 - "$VAULT" "$D" "$PW_M1" 1 <<'PY'
import base64, os, subprocess, sys
vault, d, pw, three = sys.argv[1:5]
p = subprocess.Popen([vault, "serve", d], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     env=dict(os.environ, ARCHOERA_VAULT_BACKEND="file"))
def cmd(l, pl=None):
    p.stdin.write((l + "\n" + (pl + "\n" if pl else "")).encode()); p.stdin.flush()
    return p.stdout.readline().decode().strip()
b32 = base64.b64encode(os.urandom(32)).decode()
b16 = base64.b64encode(os.urandom(16)).decode()
assert cmd("handshake %s %s %s" % (b32, b16, base64.b64encode(pw.encode()).decode())
           ).startswith("ok handshake")
for uid, val in (("kugou:session", "golden-kugou-session-token"),
                 ("netease:cookie", "golden-netease-cookie-value")):
    assert cmd("set " + uid, base64.b64encode(val.encode()).decode()) == "ok"
cmd("quit"); p.wait(timeout=30)
rm -f "$D/vault.lock"
PY
KDF_NOTE="最小档 m=8192 / t=1 / p=1" write_readme "$D" "slots m1（'S'，仅口令槽）" "口令 \`$PW_M1\`"
write_unlock "$D" '{"mode":"m1","password":"'"$PW_M1"'","kdf":{"m":8192,"t":1,"p":1},
  "slot_kinds":[1],
  "entries":{"kugou:session":"golden-kugou-session-token","netease:cookie":"golden-netease-cookie-value"}}' 

echo "== m2a（口令 + 设备 + 恢复码，最小 KDF）=="
D="$ROOT/m2a"; mkdir -p "$D"
OUT=$(printf '%s\n' "$PW_M2A" | "$VAULT" init-m2a "$D" --kdf-m 8192 --kdf-t 1 --kdf-p 1)
CODE=$(echo "$OUT" | awk '{print $3}')
python3 - "$VAULT" "$D" 1 <<'PY'
import base64, os, subprocess, sys
vault, d, three = sys.argv[1:4]
p = subprocess.Popen([vault, "serve", d], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     env=dict(os.environ, ARCHOERA_VAULT_BACKEND="file"))
def cmd(l, pl=None):
    p.stdin.write((l + "\n" + (pl + "\n" if pl else "")).encode()); p.stdin.flush()
    return p.stdout.readline().decode().strip()
b32 = base64.b64encode(os.urandom(32)).decode()
b16 = base64.b64encode(os.urandom(16)).decode()
assert cmd("handshake %s %s %s" % (b32, b16, base64.b64encode(b"golden-m2a-pw").decode())
           ).startswith("ok handshake")
for uid, val in (("kugou:session", "golden-kugou-session-token"),
                 ("netease:cookie", "golden-netease-cookie-value")):
    assert cmd("set " + uid, base64.b64encode(val.encode()).decode()) == "ok"
cmd("quit"); p.wait(timeout=30)
rm -f "$D/vault.lock"
PY
KDF_NOTE="最小档 m=8192 / t=1 / p=1（仅口令+设备槽）" write_readme "$D" "slots m2a（'S'，口令+设备槽 + 恢复槽）" "口令 \`$PW_M2A\`（或恢复码）" "$CODE"
write_unlock "$D" '{"mode":"m2a","password":"'"$PW_M2A"'","recovery_code":"'"$CODE"'",
  "kdf":{"m":8192,"t":1,"p":1},"slot_kinds":[4,3],
  "entries":{"kugou:session":"golden-kugou-session-token","netease:cookie":"golden-netease-cookie-value"}}' 

echo "== m2b（仅设备）=="
D="$ROOT/m2b"; mkdir -p "$D"
"$VAULT" init-m2b "$D" >/dev/null
python3 - "$VAULT" "$D" 1 <<'PY'
import base64, os, subprocess, sys
vault, d, three = sys.argv[1:4]
p = subprocess.Popen([vault, "serve", d], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     env=dict(os.environ, ARCHOERA_VAULT_BACKEND="file"))
def cmd(l, pl=None):
    p.stdin.write((l + "\n" + (pl + "\n" if pl else "")).encode()); p.stdin.flush()
    return p.stdout.readline().decode().strip()
b32 = base64.b64encode(os.urandom(32)).decode()
b16 = base64.b64encode(os.urandom(16)).decode()
assert cmd("handshake %s %s" % (b32, b16)).startswith("ok handshake")
for uid, val in (("kugou:session", "golden-kugou-session-token"),
                 ("netease:cookie", "golden-netease-cookie-value")):
    assert cmd("set " + uid, base64.b64encode(val.encode()).decode()) == "ok"
cmd("quit"); p.wait(timeout=30)
rm -f "$D/vault.lock"
PY
write_readme "$D" "slots m2b（'S'，仅设备槽）" "\`device.key\`（本机免密）"
write_unlock "$D" '{"mode":"m2b","kdf":null,"slot_kinds":[2],
  "entries":{"kugou:session":"golden-kugou-session-token","netease:cookie":"golden-netease-cookie-value"}}' 

cat > "$ROOT/README.md" <<'EOF'
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
EOF

echo
echo "夹具已生成："
find "$ROOT" -type f | sort
echo
echo "注意：夹具入库需绕过 .gitignore 的 *.key 规则（见仓库 .gitignore 中的例外项）。"
