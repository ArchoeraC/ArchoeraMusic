#!/usr/bin/env bash
# 跨实现字节兼容（cross-parity）验证：C# vault（NativeAOT）与 Rust vault 互解互读。
#
# 覆盖：
#   - crypto（file 后端）：C# 建 → Rust 写/读；Rust 建 → C# 写/读
#   - slots m1：C# 建 → Rust 写 → C# 读；Rust 建 → C# 写 → Rust 读
#   - slots m2a：C# 建 → Rust 口令+设备写/读 + Rust 恢复码读；Rust 建 → C# 口令写 → Rust 恢复码读
#   - slots m2b：C# 建 → Rust 写 → C# 读；Rust 建 → C# 写 → Rust 读
#
# 依赖：../vault/build/archoera-vault-test（C# 测试产物）+ ./build/archoera-vault-test。
set -euo pipefail
cd "$(dirname "$0")"

CS="../vault/build/archoera-vault-test"
RS="build/archoera-vault-test"
[ -x "$CS" ] || { echo "缺少 C# 测试产物：请先 (cd ../vault && ./build-test.sh)" >&2; exit 1; }
[ -x "$RS" ] || { echo "缺少 Rust 测试产物：请先 ./build-test.sh" >&2; exit 1; }

export ARCHOERA_VAULT_BACKEND=file

fail() { echo "✗ FAIL: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }

HELPER="$(mktemp)"
T1=""; T2=""; T3=""; T4=""; T5=""; T6=""; T7=""; T8=""
trap 'rm -f "$HELPER"; rm -rf "$T1" "$T2" "$T3" "$T4" "$T5" "$T6" "$T7" "$T8"' EXIT

cat > "$HELPER" <<'PY'
# helper.py <vault> <dataDir> <mode> <secret> <op>
#   mode: crypto | m1 | m2a | m2a-rec | m2b
#   op  : write | read
import base64, os, subprocess, sys

vault, data, mode, secret, op = sys.argv[1:6]
base_mode = "m2a" if mode == "m2a-rec" else mode
value = ("parity-" + base_mode).encode()
uid = "parity:" + base_mode

def clear_lockout():
    lk = os.path.join(data, "vault.lockout")
    if os.path.exists(lk):
        os.remove(lk)

fields = [base64.b64encode(os.urandom(32)).decode(),
          base64.b64encode(os.urandom(16)).decode()]
if mode in ("m1", "m2a"):
    fields.append(base64.b64encode(secret.encode()).decode())
elif mode == "m2a-rec":
    fields.append(base64.b64encode(secret.encode()).decode())
    fields.append(base64.b64encode(b"rec").decode())

clear_lockout()
p = subprocess.Popen([vault, "serve", data], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def cmd(line, payload=None):
    if payload is None:
        p.stdin.write((line + "\n").encode())
    else:
        p.stdin.write((line + "\n" + payload + "\n").encode())
    p.stdin.flush()
    return p.stdout.readline().decode().rstrip("\n")

resp = cmd("handshake " + " ".join(fields))
assert resp.startswith("ok handshake"), "handshake 失败: %r" % resp
enc = base64.b64encode(value).decode()
if op == "write":
    assert cmd("set %s" % uid, enc) == "ok", "set 失败"
    assert cmd("get %s" % uid) == "ok " + enc, "写后回读不一致"
else:
    got = cmd("get %s" % uid)
    assert got == "ok " + enc, "跨实现读取不一致（%s）: %r" % (op, got)
assert cmd("quit") == "ok", "quit 失败"
p.wait(timeout=10)
assert p.returncode == 0, "退出码 %r" % p.returncode
print("ok")
PY

hs() { python3 "$HELPER" "$@"; }

# ── crypto（file 后端）────────────────────────────────────────────────
T1=$(mktemp -d); T2=$(mktemp -d)
K1=$(python3 -c "import secrets;print(secrets.token_hex(32))")
K2=$(python3 -c "import secrets;print(secrets.token_hex(32))")
printf '%s\n' "$K1" | "$CS" init-file "$T1" --key-stdin >/dev/null
hs "$RS" "$T1" crypto "" write >/dev/null
hs "$CS" "$T1" crypto "" read  >/dev/null
printf '%s\n' "$K2" | "$RS" init-file "$T2" --key-stdin >/dev/null
hs "$CS" "$T2" crypto "" write >/dev/null
hs "$RS" "$T2" crypto "" read  >/dev/null
pass "crypto-file：C# 建→Rust 写→C# 读；Rust 建→C# 写→Rust 读（双向互解）"

# ── m1 ────────────────────────────────────────────────────────────────
T3=$(mktemp -d); T4=$(mktemp -d)
P1="m1-parity-口令"; P2="m1-parity-rs"
printf '%s\n' "$P1" | "$CS" init-m1 "$T3" >/dev/null
hs "$RS" "$T3" m1 "$P1" write >/dev/null
hs "$CS" "$T3" m1 "$P1" read  >/dev/null
printf '%s\n' "$P2" | "$RS" init-m1 "$T4" >/dev/null
hs "$CS" "$T4" m1 "$P2" write >/dev/null
hs "$RS" "$T4" m1 "$P2" read  >/dev/null
pass "slots m1：C# 建→Rust 写→C# 读；Rust 建→C# 写→Rust 读（含 Argon2id AD 派生一致）"

# ── m2a（口令+设备 + 恢复码）──────────────────────────────────────────
T5=$(mktemp -d); T6=$(mktemp -d)
Q1="m2a-parity-设备"; Q2="m2a-parity-rs"
OUT5=$(printf '%s\n' "$Q1" | "$CS" init-m2a "$T5")
CODE5=$(printf '%s\n' "$OUT5" | awk '{print $3}')
hs "$RS" "$T5" m2a "$Q1" write >/dev/null
hs "$CS" "$T5" m2a "$Q1" read  >/dev/null
hs "$RS" "$T5" m2a-rec "$CODE5" read >/dev/null
OUT6=$(printf '%s\n' "$Q2" | "$RS" init-m2a "$T6")
CODE6=$(printf '%s\n' "$OUT6" | awk '{print $3}')
hs "$CS" "$T6" m2a "$Q2" write >/dev/null
hs "$RS" "$T6" m2a "$Q2" read  >/dev/null
hs "$CS" "$T6" m2a-rec "$CODE6" read >/dev/null
pass "slots m2a：C#/Rust 建 → 对端口令+设备写读；对方恢复码可读（HKDF pwdev/recovery 一致）"

# ── m2b（仅设备）─────────────────────────────────────────────────────
T7=$(mktemp -d); T8=$(mktemp -d)
"$CS" init-m2b "$T7" >/dev/null
hs "$RS" "$T7" m2b "" write >/dev/null
hs "$CS" "$T7" m2b "" read  >/dev/null
"$RS" init-m2b "$T8" >/dev/null
hs "$CS" "$T8" m2b "" write >/dev/null
hs "$RS" "$T8" m2b "" read  >/dev/null
pass "slots m2b：C#/Rust 双向互解互读（HKDF device 一致）"

echo "跨实现字节兼容全部通过 ✔"
